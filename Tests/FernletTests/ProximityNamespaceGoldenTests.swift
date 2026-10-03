// ProximityNamespaceGoldenTests.swift
// FernletTests
//
// Every byte string `ProximityNamespace.fernlet` carries besides its payload vocabulary, its radios'
// presentation strings and its peer-name policy, each pinned by a literal written by hand before any
// of them moved onto the namespace (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2), and
// every ProximityKit reader of those values held to the namespace it is handed. Moving a value onto
// the namespace moves no byte; this file is how that claim is checked rather than asserted. The
// vocabulary, the presentation strings and the peer-name policy are ProximityVocabularyGoldenTests'.
//
// Fifteen groups of claims:
//
// 1. **The golden table.** One row per value: the 41 domain-separation labels (the 39 protocol
//    labels, which are the 38 core registry purposes and the epoch domain no registry holds, then the
//    two feature salts `.fernlet` declares), the three radios' service types and ALPNs, the mesh
//    heartbeat, the QR scheme, the identity keychain service and its four device accounts, the two
//    seal-key rows, the storage directory and its three on-disk names, and the radios' log
//    subsystem. Plus the QR host, which stays a ProximityKit constant but travels beside the scheme.
//    64 rows, each a frozen literal beside the accessor production reads: `.fernlet`'s field, for the
//    two seal-key services the production derivation called with `.fernlet`, and for the two feature
//    salts the registry entry the identity's heart-drop and presence derivations read.
// 2. **Known answers for the six labels nothing else pinned** (`fernlet.mesh.groupkey.v1`,
//    `fernlet.mesh.groupkey.wrap.aead.v2`, `fernlet.mesh.encrypted-metadata.aead.v2`,
//    `fernlet.mesh.routed.content-key.v1`, `fernlet.mesh.session-context.v1`,
//    `fernlet.mesh.routed-store.v1`): column keys and blobs that ColumnCrypto and the two mesh stores
//    must open, and literal-built group-key, transport, routed-key and metadata blobs that production
//    must open. A consumer that reads the wrong field opens nothing, so these pin the CONSUMER too.
// 3. **Transcripts, epoch ids and wire tokens.** The framed label at the front of the channel
//    introduction and of both QR transcripts, the two epoch ids the epoch domain derives, the mesh
//    messages and record kinds of `.fernlet` that are spelled exactly like a signature label, and the
//    two at-rest format names whose unused mirror tokens were deleted, as literal rows.
// 4. **The format constants that stay ProximityKit's** (`FPT2`, `FGK2`, `FMGM2`, `FMRI1`, the
//    column byte `0x03`, the QR host, query key and version, the `corrupt` and `chunk` extensions):
//    not namespace values, but each sits in code right beside one.
// 5. **`.fernlet` against the table.** Every value it carries equals its frozen literal, every label
//    has the role ProximityKit fixes for its field, it is sound, the 40 labels FernletCrypto's
//    registry also declares (38 protocol labels and both feature salts) are spelled alike and the
//    signature twins accept the same transcripts, no label of the registry's 81 and its 41 together
//    is a byte prefix of another (CDST's sealed-backup pair aside), and reflection finds no label
//    field `labelRows` leaves out, the feature group's declared salts listed after the fixed ones.
// 6. **Every hash and transcript consumer against its field's role.** The bytes each production
//    consumer writes begin with that field's `prefixBytes`: 19 signed transcripts, 8 hash preimages
//    and the 2 authenticated-data builders, one cell each.
// 7. **A foreign namespace.** One built from another app's literals collides with `.fernlet` nowhere,
//    and no signature purpose of either accepts a transcript framed for the other, except Fernlet's
//    two verify-only legacy labels, which accept every transcript by construction. Its payload
//    vocabulary and presentation strings share no string with `.fernlet`'s, whose own values
//    ProximityVocabularyGoldenTests pins.
// 8. **The supply path.** `IdentityService(namespace:)` takes its keychain service from the
//    namespace it is handed (Fernlet's frozen service for `.fernlet`, another app's for another
//    app's, an explicit service over either), and its namespace overloads of `sign` and `verify`
//    treat each label by its role: the 19 writable signature labels sign and verify, the verify-only
//    legacy pair verifies and never signs, and no other label does either.
// 9. **The signed transcripts read the namespace they are handed.** The labels the test bindings pass
//    are `.fernlet`'s own; the membership inventory digest is hashed over its field's prefix; a
//    schema-v1 envelope and a pre-WI-6 admission token still verify under `.fernlet`, whose family
//    accepts its legacy peers, and are refused under a family that refuses them; an envelope and an
//    admission token each verify under the namespace they were signed in and are refused under the
//    other, both ways; and a membership verifier and the ledger adoption accept a foreign-signed
//    admission, departure and digest only under the foreign family they hold or are handed.
// 10. **The routed transcripts, the introduction and the QR read the namespace they are handed.** A
//     verify QR carries its identity's scheme and parses and validates only in its own namespace; a
//     verify response verifies only under the label it was framed in; a coach ceremony runs under its
//     identity's namespace and a Fernlet scanner refuses another app's code; the six routed doors
//     accept only what was signed under the labels they hold; the channel-introduction exchange frames
//     its transcript and checks the peer's under its own copy; and the manager signs the channel
//     introduction its radio frames under the namespace it built that radio from.
// 11. **The hashes, seals, salts and the epoch read the namespace they are handed.** The routed
//     digests and ids are SHA-256 over the field prefix of the namespace they are handed; the chunk
//     verifier, the reassembler, the chunker and the routed store measure a chunk or an item only
//     under the labels they hold or are handed; the item seal and the content-key wrap open only
//     under the namespace they were sealed in, the salt and the authenticated data each on its own;
//     an identity's transport seal and group-key wrap open only for an identity of its namespace;
//     the manager opens encrypted metadata under its host's namespace; and every epoch id is
//     derived under the namespace's raw epoch domain.
// 12. **The radios.** Each radio holds what the namespace it was built from says (Fernlet's frozen
//     values under `.fernlet`, another app's under another app's), and the mesh radio's heartbeat
//     and channel-binding consumers take those values from the radio, whole.
// 13. **The at-rest names and rows read the namespace.** The two stores write and read their files
//     and seal keys under the names the namespace their scope carries gives, Fernlet's or another
//     app's; a host with no sidecar root or scope of its own gets them built from its namespace; and
//     an identity provisions, and its provisioning rule names, the four rows its namespace names.
// 14. **The column seal and the install binding.** ProximityKit's copy, `ProximityColumnCrypto`,
//     derives group 2's known column keys from `.fernlet`'s fields and opens group 2's known blobs;
//     it and FernletCrypto's `ColumnCrypto` open each other's blobs, for both labels, both ways; it
//     refuses exactly where `ColumnCrypto` refuses, by the same name; each store seals under its
//     scope namespace's label and its scope's binding, and under nothing else; Fernlet's adapter
//     answers `DeviceBindingID` at each call, a mid-operation flip included; and a host's default
//     scopes carry the binding it supplies. Every scope here carries a binding (Fernlet's adapter,
//     unless a cell supplies its own).
// 15. **The keychain mechanism.** For every keychain row `.fernlet` names, each query dictionary
//     ProximityKit's copy, `ProximityKeychainItem`, issues is the one FernletFoundation's
//     `KeychainItem` issues for the same service and account, read out of FernletFoundation's own
//     source; on an isolated service the copy and the original read, list and delete each other's
//     rows, a device-only row and its synchronized twin alike; the copy fails exactly where the
//     original fails, with the same answers and the same two audit lines; and ProximityKit's code
//     reaches the keychain only through the copy.
//
// Every `IdentityService` here is built with its namespace spelled out (`namespace: .fernlet` for
// Fernlet's), never through the test target's bindings (ProximityNamespaceTestBindings.swift): a
// suite that pins values names the namespace it pins them under, and so does every consumer here
// that takes labels (`in: .fernlet`, `purposes: .fernlet`, `family: .fernlet`).
//
// Every hex vector below was derived from the FORMAT by an independent Python re-implementation,
// proved honest first by reproducing vectors the repo already pins (SealedBackupFormatPinTests' two
// escrow KATs, MeshMembershipEventGoldenTests' epoch-heads golden, MeshRoutedManifestGoldenTests' wrap
// AAD), then cross-checked in CryptoKit — never copied out of Swift's output.

import CryptoKit
import FernletConnections
import FernletDomainModel
import FernletFoundation
import Foundation
import os
import Security
import Testing
@testable import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

// MARK: - The table's row

/// One value `ProximityNamespace.fernlet` carries: the namespace field it fills, its FROZEN literal,
/// and where production reads it.
struct NamespaceGoldenRow: Sendable {

    /// The part of the namespace a row belongs to; the shape cell counts rows by it.
    enum Group: Hashable, Sendable {
        /// A domain-separation label (`family.purposes.*`).
        case label
        /// A radio's service type or ALPN, or the mesh heartbeat (`family.radios.*`).
        case radio
        /// The verify QR's URL scheme, and the QR host that travels beside it.
        case verifyQR
        /// A keychain service or account (`installation.keychain.*`).
        case keychain
        /// The storage directory or an on-disk name (`installation.storage.*`).
        case storage
        /// The radios' `os.Logger` subsystem (`installation.logSubsystem`).
        case logSubsystem
    }

    /// Where production reads the value. **The only column a commit that moves a value may edit.**
    enum Today: Equatable, Sendable {
        /// A value the test can name — internal ones through `@testable` — compared as its UTF-8.
        case text(String)
        /// A value that is bytes rather than text: the heartbeat datagram.
        case bytes(Data)
        /// A value no test can name even through `@testable`. A behaviour cell pins it instead, and
        /// selects the row by `field`, so that cell keeps running after the row is re-pointed.
        case unnamed
    }

    /// Which part of the namespace the row belongs to.
    let group: Group
    /// The `ProximityNamespace` field path the value fills (the plan's A0.2 design spells them).
    let field: String
    /// The bytes, written by hand from the A0.2 census. Never computed from a constant; never edited.
    let frozen: String
    /// The accessor production reads.
    let today: Today

    /// One row.
    init(_ group: Group, _ field: String, frozen: String, today: Today) {
        self.group = group
        self.field = field
        self.frozen = frozen
        self.today = today
    }

    /// Today's bytes, or nil for an ``Today/unnamed`` row.
    var todayBytes: Data? {
        switch today {
        case .text(let text): return Data(text.utf8)
        case .bytes(let bytes): return bytes
        case .unnamed: return nil
        }
    }
}

// MARK: - The suite

/// Every byte string `ProximityNamespace.fernlet` carries, pinned by literal — the gate every change
/// to a value or its reader has to pass unchanged.
///
/// **The rule for every commit: re-point the `today:` column, never the `frozen:` one.** A row's
/// `frozen` literal was written by hand from the A0.2 census and never changes again. A commit that
/// moves a value edits only that row's `today` accessor, to the path production then reads — as
/// `.text(FernletCryptoPurpose.Signature.meshRoutedChunkV1.rawValue)` became `.fernlet`'s field —
/// and the row has to stay green. The same holds for every hex vector here: a failing vector or row
/// is a WIRE or AT-REST decision, so it is never re-pinned from Swift's output to go green. Failure
/// messages print the actual bytes so a deliberate change can be argued from them.
@MainActor
@Suite(.serialized)
struct ProximityNamespaceGoldenTests {

    // MARK: Group 1 — the golden table

    /// The 64 rows, in the design's field order.
    static var table: [NamespaceGoldenRow] {
        signatureRows + otherLabelRows + featureLabelRows + radioRows + verifyQRRows + keychainRows
            + storageRows + logRows
    }

    /// The 21 signature labels: 17 length-prefixed transcripts, the two raw-prefixed QR transcripts
    /// and the verify-only legacy pair.
    ///
    /// Since step A0.2.4 the envelope, admission-token, membership, quorum and key-agreement labels
    /// and the legacy pair are read off `.fernlet` (`fernlet` below), because production reads them
    /// off the host's namespace; since step A0.2.5 the routed, channel-introduction and QR rows are
    /// too, so every signature row now reads the field production reads.
    private static var signatureRows: [NamespaceGoldenRow] {
        let fernlet = ProximityNamespace.fernlet.family.purposes.signature
        let field = "family.purposes.signature."
        return [
            NamespaceGoldenRow(.label, field + "identityEnvelopeV2", frozen: "fernlet.canonical.identity-envelope.v2",
                               today: .text(fernlet.identityEnvelopeV2.rawValue)),
            NamespaceGoldenRow(.label, field + "meshAdmissionTokenV2", frozen: "fernlet.canonical.mesh-admission-token.v2",
                               today: .text(fernlet.meshAdmissionTokenV2.rawValue)),
            NamespaceGoldenRow(.label, field + "meshChannelIntroductionV1", frozen: "fernlet.mesh.channel-introduction.v1",
                               today: .text(fernlet.meshChannelIntroductionV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshMemberDepartureV1", frozen: "fernlet.mesh.member-departure.v1",
                               today: .text(fernlet.meshMemberDepartureV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshMemberRemovalV1", frozen: "fernlet.mesh.member-removal.v1",
                               today: .text(fernlet.meshMemberRemovalV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshTerminatedV1", frozen: "fernlet.mesh.terminated.v1",
                               today: .text(fernlet.meshTerminatedV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshInventoryDigestV1", frozen: "fernlet.mesh.inventory-digest.v1",
                               today: .text(fernlet.meshInventoryDigestV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshEpochHeadsV1", frozen: "fernlet.mesh.epoch-heads.v1",
                               today: .text(fernlet.meshEpochHeadsV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRemovalProposalV1", frozen: "fernlet.mesh.removal-proposal.v1",
                               today: .text(fernlet.meshRemovalProposalV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRemovalVoteV1", frozen: "fernlet.mesh.removal-vote.v1",
                               today: .text(fernlet.meshRemovalVoteV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshKeyAgreementV1", frozen: "fernlet.mesh.key-agreement.v1",
                               today: .text(fernlet.meshKeyAgreementV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedManifestV1", frozen: "fernlet.mesh.routed-manifest.v1",
                               today: .text(fernlet.meshRoutedManifestV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedChunkV1", frozen: "fernlet.mesh.routed-chunk.v1",
                               today: .text(fernlet.meshRoutedChunkV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshCustodyReceiptV1", frozen: "fernlet.mesh.custody-receipt.v1",
                               today: .text(fernlet.meshCustodyReceiptV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRecipientReceiptV1", frozen: "fernlet.mesh.recipient-receipt.v1",
                               today: .text(fernlet.meshRecipientReceiptV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedInventoryDigestV1",
                               frozen: "fernlet.mesh.routed-inventory-digest.v1",
                               today: .text(fernlet.meshRoutedInventoryDigestV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedDrainAnswerV1", frozen: "fernlet.mesh.routed-drain-answer.v1",
                               today: .text(fernlet.meshRoutedDrainAnswerV1.rawValue)),
            NamespaceGoldenRow(.label, field + "proximityQRIdentityV1", frozen: "fernlet.verify.qr.v1",
                               today: .text(fernlet.proximityQRIdentityV1.rawValue)),
            NamespaceGoldenRow(.label, field + "proximityQRResponseV1", frozen: "fernlet.verify.response.v1",
                               today: .text(fernlet.proximityQRResponseV1.rawValue)),
            NamespaceGoldenRow(.label, field + "legacyV1.identityEnvelopeV1", frozen: "fernlet.canonical.identity-envelope.v1",
                               today: .text(fernlet.legacyV1.identityEnvelopeV1?.rawValue ?? "")),
            NamespaceGoldenRow(.label, field + "legacyV1.meshAdmissionTokenV1",
                               frozen: "fernlet.canonical.mesh-admission-token.v1",
                               today: .text(fernlet.legacyV1.meshAdmissionTokenV1?.rawValue ?? ""))
        ]
    }

    /// The 18 other labels: six key-derivation labels, five AEAD labels, seven hash domains — the
    /// last of them the ProximityKit-local epoch domain, which no registry or domain test covers.
    /// Since step A0.2.4 the membership inventory digest's hash domain is read off `.fernlet`
    /// (`fernletHash` below), as production reads it off the host's namespace; since step A0.2.6 the
    /// three HKDF salts, the five AEAD labels and the other six hash domains are too, the epoch
    /// domain among them (its `MeshEpochBounds.derivationDomain` is gone), and since step A0.2.7 the
    /// TLS exporter label, which the mesh radio reads off the namespace it is built from. Since step
    /// A0.2.9 the two column seals are too, which the two sealed mesh stores read off their scope's
    /// namespace, so every label row now reads the field production reads.
    private static var otherLabelRows: [NamespaceGoldenRow] {
        let fernletDerivation = ProximityNamespace.fernlet.family.purposes.keyDerivation
        let fernletAEAD = ProximityNamespace.fernlet.family.purposes.aead
        let fernletHash = ProximityNamespace.fernlet.family.purposes.hash
        let derivation = "family.purposes.keyDerivation."
        let aead = "family.purposes.aead."
        let hash = "family.purposes.hash."
        return [
            NamespaceGoldenRow(.label, derivation + "proximityTransportV1", frozen: "fernlet.proximity.v1",
                               today: .text(fernletDerivation.proximityTransportV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshGroupKeyWrapV1", frozen: "fernlet.mesh.groupkey.v1",
                               today: .text(fernletDerivation.meshGroupKeyWrapV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshTLSExporterV1", frozen: "fernlet.mesh.tls-exporter.v1",
                               today: .text(fernletDerivation.meshTLSExporterV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshRoutedContentKeyWrapV1", frozen: "fernlet.mesh.routed.content-key.v1",
                               today: .text(fernletDerivation.meshRoutedContentKeyWrapV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshSessionContextV1", frozen: "fernlet.mesh.session-context.v1",
                               today: .text(fernletDerivation.meshSessionContextV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshRoutedStoreV1", frozen: "fernlet.mesh.routed-store.v1",
                               today: .text(fernletDerivation.meshRoutedStoreV1.rawValue)),
            NamespaceGoldenRow(.label, aead + "proximityTransportV2", frozen: "fernlet.proximity.transport.aead.v2",
                               today: .text(fernletAEAD.proximityTransportV2.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshGroupKeyWrapV2", frozen: "fernlet.mesh.groupkey.wrap.aead.v2",
                               today: .text(fernletAEAD.meshGroupKeyWrapV2.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshEncryptedMetadataV2", frozen: "fernlet.mesh.encrypted-metadata.aead.v2",
                               today: .text(fernletAEAD.meshEncryptedMetadataV2.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshRoutedContentKeyWrapV1",
                               frozen: "fernlet.mesh.routed.content-key.wrap.aead.v1",
                               today: .text(fernletAEAD.meshRoutedContentKeyWrapV1.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshRoutedItemV1", frozen: "fernlet.mesh.routed.item.aead.v1",
                               today: .text(fernletAEAD.meshRoutedItemV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshInventoryDigestV1", frozen: "fernlet.mesh.inventory-digest.hash.v1",
                               today: .text(fernletHash.meshInventoryDigestV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRoutedContentV1", frozen: "fernlet.mesh.routed-content.hash.v1",
                               today: .text(fernletHash.meshRoutedContentV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRoutedChunkV1", frozen: "fernlet.mesh.routed-chunk.hash.v1",
                               today: .text(fernletHash.meshRoutedChunkV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRoutedChunkIDV1", frozen: "fernlet.mesh.routed-chunk-id.hash.v1",
                               today: .text(fernletHash.meshRoutedChunkIDV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshCustodyReceiptIDV1", frozen: "fernlet.mesh.custody-receipt-id.hash.v1",
                               today: .text(fernletHash.meshCustodyReceiptIDV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRecipientReceiptIDV1", frozen: "fernlet.mesh.recipient-receipt-id.hash.v1",
                               today: .text(fernletHash.meshRecipientReceiptIDV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshEpochIDV1", frozen: "fernlet.mesh.epoch.v1",
                               today: .text(fernletHash.meshEpochIDV1.rawValue))
        ]
    }

    /// The two feature salts `.fernlet` declares (`family.purposes.feature`), after the hash rows as
    /// `labelRows` lists them: the heart dead-drop's and presence's pair-secret salts, which
    /// ProximityKit's `pairSecret(with:purpose:)` derives under only when a namespace declares them.
    /// The identity's heart-drop and presence derivations read the salts' FernletCrypto registry
    /// twins, so that is what the `today` column reads; `everyFernletValueIsItsFrozenLiteral()`
    /// holds `.fernlet`'s declared values to the same literals, and the twin cells hold the two
    /// spellings equal.
    private static var featureLabelRows: [NamespaceGoldenRow] {
        let feature = "family.purposes.feature."
        return [
            NamespaceGoldenRow(.label, feature + "heartDropPairV1", frozen: "fernlet.heartdrop.v1",
                               today: .text(FernletCryptoPurpose.KeyDerivation.heartDropPairV1.rawValue)),
            NamespaceGoldenRow(.label, feature + "presencePairV1", frozen: "fernlet.presence.tag.v1",
                               today: .text(FernletCryptoPurpose.KeyDerivation.presencePairV1.rawValue))
        ]
    }

    /// The three radios' service types and ALPNs, and the heartbeat the mesh radio filters by equality.
    ///
    /// Read off `.fernlet` since step A0.2.7, when each radio began taking them from the namespace its
    /// manager hands it (``theRadiosReadTheirValuesOffTheNamespace()`` pins those reads).
    private static var radioRows: [NamespaceGoldenRow] {
        [
            NamespaceGoldenRow(.radio, "family.radios.mesh.serviceType", frozen: "_fernlet-mesh2._udp",
                               today: .text(ProximityNamespace.fernlet.family.radios.mesh.serviceType)),
            NamespaceGoldenRow(.radio, "family.radios.mesh.alpn", frozen: "fernlet-mesh-v1",
                               today: .text(ProximityNamespace.fernlet.family.radios.mesh.alpn)),
            NamespaceGoldenRow(.radio, "family.radios.presence.serviceType", frozen: "_fernlet-near2._udp",
                               today: .text(ProximityNamespace.fernlet.family.radios.presence.serviceType)),
            NamespaceGoldenRow(.radio, "family.radios.presence.alpn", frozen: "fernlet-near-v1",
                               today: .text(ProximityNamespace.fernlet.family.radios.presence.alpn)),
            NamespaceGoldenRow(.radio, "family.radios.recipeShare.serviceType", frozen: "_fernlet-recipe2._udp",
                               today: .text(ProximityNamespace.fernlet.family.radios.recipeShare.serviceType)),
            NamespaceGoldenRow(.radio, "family.radios.recipeShare.alpn", frozen: "fernlet-recipe-v1",
                               today: .text(ProximityNamespace.fernlet.family.radios.recipeShare.alpn)),
            NamespaceGoldenRow(.radio, "family.radios.meshHeartbeat", frozen: "fernlet-mesh-heartbeat",
                               today: .bytes(ProximityNamespace.fernlet.family.radios.meshHeartbeat))
        ]
    }

    /// The QR's scheme, which the namespace carries, and its host, which stays a ProximityKit
    /// constant (``theVerifyQRURLKeepsItsHostQueryKeyAndVersion()`` pins it by behaviour as well).
    /// Since step A0.2.5 the scheme is read off `.fernlet`, as production reads it off the host's
    /// namespace (``theVerifyQRReadsItsSchemeAndLabelOffTheNamespace()`` pins that read).
    private static var verifyQRRows: [NamespaceGoldenRow] {
        [
            NamespaceGoldenRow(.verifyQR, "family.verifyQR.urlScheme", frozen: "fernlet",
                               today: .text(ProximityNamespace.fernlet.family.verifyQR.urlScheme)),
            NamespaceGoldenRow(.verifyQR, "proximityKit.verifyQR.urlHost", frozen: "verify",
                               today: .text(ProximityVerifyQR.urlHost))
        ]
    }

    /// The identity service and its four device accounts, and the two seal-key rows.
    ///
    /// The identity service is read off `.fernlet` since step A0.2.3, when `IdentityService` began
    /// taking it from the host's namespace (``theIdentityKeychainServiceIsReadOffTheNamespace()``
    /// pins that read). Since step A0.2.8 the four accounts and both seal-key accounts are read off
    /// `.fernlet` too, as the identity and the stores read them off the namespace they hold, and the
    /// two seal-key services through the derivation the app and the isolation walls use, called with
    /// `.fernlet` (the production heart-drop service in, the namespace's production service out): the
    /// production scopes' own spellings are banned by substring in every other test file.
    private static var keychainRows: [NamespaceGoldenRow] {
        let identity = "installation.keychain.identity."
        let heartDrop = HeartPrekeyStore.keychainService
        let fernlet = ProximityNamespace.fernlet.installation.keychain
        return [
            NamespaceGoldenRow(.keychain, identity + "service", frozen: "com.fernlet.identity",
                               today: .text(ProximityNamespace.fernlet.installation.keychain.identity.service)),
            NamespaceGoldenRow(.keychain, identity + "signingPrivateKey", frozen: "signingPrivateKey",
                               today: .text(fernlet.identity.signingPrivateKey)),
            NamespaceGoldenRow(.keychain, identity + "keyAgreementPrivateKey", frozen: "keyAgreementPrivateKey",
                               today: .text(fernlet.identity.keyAgreementPrivateKey)),
            NamespaceGoldenRow(.keychain, identity + "signingPublicKeyCache", frozen: "signingPublicKeyCache",
                               today: .text(fernlet.identity.signingPublicKeyCache)),
            NamespaceGoldenRow(.keychain, identity + "keyAgreementPublicKeyCache", frozen: "keyAgreementPublicKeyCache",
                               today: .text(fernlet.identity.keyAgreementPublicKeyCache)),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshSessionSealKey.service",
                               frozen: "com.fernlet.mesh-session",
                               today: .text(MeshSessionStorageScope.keychainService(besideHeartDrop: heartDrop, in: .fernlet))),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshSessionSealKey.account", frozen: "meshSessionContextKey",
                               today: .text(fernlet.meshSessionSealKey.account)),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshRoutedSealKey.service",
                               frozen: "com.fernlet.mesh-routed",
                               today: .text(MeshRoutedStorageScope.keychainService(besideHeartDrop: heartDrop, in: .fernlet))),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshRoutedSealKey.account", frozen: "meshRoutedStoreKey",
                               today: .text(fernlet.meshRoutedSealKey.account))
        ]
    }

    /// The storage directory and the three names the two sealed mesh stores write under it.
    ///
    /// Read off `.fernlet` since step A0.2.8, when the stores began taking their names from their
    /// scope's namespace and the host's default root became the namespace's `defaultDirectory` (read
    /// here through it, as the app and the host default read it). Group 2's store cells and group 13
    /// pin those reads.
    private static var storageRows: [NamespaceGoldenRow] {
        let storage = "installation.storage."
        let fernlet = ProximityNamespace.fernlet.installation.storage
        return [
            NamespaceGoldenRow(.storage, storage + "directoryName", frozen: "Fernlet",
                               today: .text(fernlet.defaultDirectory.lastPathComponent)),
            NamespaceGoldenRow(.storage, storage + "meshSessionContextFileName", frozen: "MeshSessionContext.sealed",
                               today: .text(fernlet.meshSessionContextFileName)),
            NamespaceGoldenRow(.storage, storage + "meshRoutedIndexFileName", frozen: "MeshRoutedIndex.sealed",
                               today: .text(fernlet.meshRoutedIndexFileName)),
            NamespaceGoldenRow(.storage, storage + "meshRoutedChunkDirectoryName", frozen: "MeshRoutedChunks",
                               today: .text(fernlet.meshRoutedChunkDirectoryName))
        ]
    }

    /// The radios' log subsystem, read off `.fernlet` since step A0.2.7, when each radio began building
    /// its `Logger` from the namespace it is handed. A `Logger` does not expose its subsystem, so
    /// ``theThreeRadiosLogUnderTheFrozenSubsystem()`` pins that read in each radio's source.
    private static var logRows: [NamespaceGoldenRow] {
        [NamespaceGoldenRow(.logSubsystem, Self.logSubsystemField, frozen: "com.fernlet",
                            today: .text(ProximityNamespace.fernlet.installation.logSubsystem))]
    }

    /// The four identity accounts' fields: ``theIdentityAccountsAreTheFourRowsAProvisionedIdentityWrites()``
    /// pins them by a real provision, whatever their `today` column says.
    static let identityAccountFields: Set<String> = [
        "installation.keychain.identity.signingPrivateKey",
        "installation.keychain.identity.keyAgreementPrivateKey",
        "installation.keychain.identity.signingPublicKeyCache",
        "installation.keychain.identity.keyAgreementPublicKeyCache"
    ]

    /// The log subsystem's field.
    static let logSubsystemField = "installation.logSubsystem"

    /// The table holds every namespace value exactly once, in the shape the design counts: 41 labels
    /// (the 39 protocol labels and the two feature salts), 7 radio values, the QR scheme and host, 9
    /// keychain names, 4 storage names, 1 log subsystem.
    /// The labels are pairwise distinct and none is a byte prefix of another — `signingBytes` matches
    /// by `starts(with:)` and several AADs are bare concatenations, so a prefix would be a collision.
    @Test func theTableHoldsEveryNamespaceValueOnce() {
        let table = Self.table
        #expect(table.count == 64, "the golden table has \(table.count) rows")
        let expected: [NamespaceGoldenRow.Group: Int] = [
            .label: 41, .radio: 7, .verifyQR: 2, .keychain: 9, .storage: 4, .logSubsystem: 1
        ]
        // R2: bounded by the six groups.
        for (group, count) in expected {
            let found = table.filter { $0.group == group }.count
            #expect(found == count, "\(group) has \(found) rows, the design counts \(count)")
        }
        #expect(Set(table.map(\.field)).count == table.count, "a namespace field appears twice")

        let labels = table.filter { $0.group == .label }.map { Data($0.frozen.utf8) }
        #expect(Set(labels).count == labels.count, "two labels share a spelling")
        var prefixed: [String] = []
        // R2: bounded by the 41 × 41 label pairs.
        for shorter in labels {
            for longer in labels where longer != shorter && longer.starts(with: shorter) {
                prefixed.append("\(String(decoding: shorter, as: UTF8.self)) ⊂ \(String(decoding: longer, as: UTF8.self))")
            }
        }
        #expect(prefixed.isEmpty, "labels that are byte prefixes of another: \(prefixed)")

        let unnamed = Set(table.filter { $0.today == .unnamed }.map(\.field))
        #expect(unnamed.isSubset(of: Self.identityAccountFields.union([Self.logSubsystemField])),
                "an unnamed row no behaviour cell pins: \(unnamed.sorted())")
    }

    /// The 41 labels, byte for byte.
    @Test func everyLabelIsItsFrozenSpelling() {
        #expect(Self.expectFrozen(.label) >= 41)
    }

    /// The service types, ALPNs and heartbeat of the three radios, byte for byte.
    @Test func everyRadioValueIsItsFrozenBytes() {
        #expect(Self.expectFrozen(.radio) >= 7)
    }

    /// The QR scheme and host, byte for byte.
    @Test func theVerifyQRSchemeAndHostAreTheirFrozenBytes() {
        #expect(Self.expectFrozen(.verifyQR) >= 2)
    }

    /// The identity service and both seal-key rows, byte for byte, and since step A0.2.8 the four
    /// identity accounts too, which the next cell also pins by a real provision.
    @Test func everyNamedKeychainValueIsItsFrozenBytes() {
        #expect(Self.expectFrozen(.keychain) >= 9)
    }

    /// The directory and the three on-disk names, byte for byte — and the directory resolves under
    /// Application Support, the root the design's `Storage.defaultDirectory` names: `.fernlet`'s,
    /// which the app and the host default resolve since step A0.2.8, and
    /// `ProximitySupportLayout.defaultDirectory`, which the heart-drop scope still resolves, are one
    /// path.
    @Test func everyStorageNameIsItsFrozenBytes() {
        #expect(Self.expectFrozen(.storage) >= 4)
        let expected = URL.applicationSupportDirectory
            .appendingPathComponent(Self.frozen("installation.storage.directoryName"), isDirectory: true)
        let namespaceRoot = ProximityNamespace.fernlet.installation.storage.defaultDirectory
        #expect(namespaceRoot == expected, "the namespace's sidecar root is \(namespaceRoot.path), not \(expected.path)")
        #expect(ProximitySupportLayout.defaultDirectory == expected,
                "the proximity sidecar root is \(ProximitySupportLayout.defaultDirectory.path), not \(expected.path)")
    }

    /// The four identity accounts, by what a real provision writes: `IdentityKeychainKey` is private,
    /// so a fresh identity on an isolated service is provisioned and that service's rows are listed.
    /// Exactly the four device accounts — no escrow row, which is minted only when backup is enabled.
    @Test func theIdentityAccountsAreTheFourRowsAProvisionedIdentityWrites() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        try IdentityService(namespace: .fernlet, keychainService: service).ensureProvisioned()

        let written = Set(KeychainItem.loadAll(service: service).map { $0.account })
        let frozen = Set(Self.table.filter { Self.identityAccountFields.contains($0.field) }.map(\.frozen))
        #expect(frozen.count == 4, "the table holds \(frozen.count) identity accounts")
        #expect(written == frozen, "a provisioned identity wrote \(written.sorted()); the table freezes \(frozen.sorted())")
    }

    /// The radios' log subsystem: the row reads `.fernlet`'s field, and since step A0.2.7 each radio
    /// builds its one `Logger` in `init(namespace:)` from the namespace it is handed. A `Logger` does
    /// not expose its subsystem, so that read is pinned in each radio's source: exactly one `Logger`
    /// built from `namespace.installation.logSubsystem`, and no subsystem spelled as a literal.
    @Test func theThreeRadiosLogUnderTheFrozenSubsystem() throws {
        #expect(Self.expectFrozen(.logSubsystem) == 1, "the log subsystem's row names no value")
        let fromNamespace = "Logger(subsystem: namespace.installation.logSubsystem, category: \""
        let radios = [
            "FernletKit/Sources/ProximityKit/Transport/NetworkMeshSession.swift",
            "FernletKit/Sources/ProximityKit/Transport/NetworkPresenceSession.swift",
            "FernletKit/Sources/ProximityKit/Transport/NetworkRecipeShareSession.swift"
        ]
        // R2: bounded by the three radios.
        for path in radios {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            let literals = Self.loggerSubsystems(in: code)
            #expect(literals.isEmpty, "\(path) still declares a Logger under the literal subsystem \(literals)")
            let built = code.components(separatedBy: fromNamespace).count - 1
            #expect(built == 1, "\(path) builds \(built) Loggers from the namespace's log subsystem, not one")
        }
    }

    /// Every service type the namespace carries is declared in the app's `NSBonjourServices`: a type
    /// missing there fails discovery silently on device, with no log and no error.
    @Test func everyServiceTypeIsDeclaredInTheAppInfoPlist() throws {
        let declared = try NoTrackingBoundaryTests.declaredBonjourServiceTypes()
        #expect(!declared.isEmpty, "App/Fernlet/Info.plist declared no NSBonjourServices — the reader is broken")
        let serviceTypes = Self.table.filter { $0.field.hasSuffix(".serviceType") }.map(\.frozen)
        #expect(serviceTypes.count == 3)
        // R2: bounded by the three radios.
        for serviceType in serviceTypes {
            #expect(declared.contains(serviceType), "\(serviceType) is not in App/Fernlet/Info.plist NSBonjourServices")
        }
    }

    // MARK: Group 2 — known answers for the labels nothing else pinned

    /// The content key every column vector derives from: `00 01 … 1f`, FernletLockCryptoTests' key.
    static let columnContentKey = SymmetricKey(data: sequence(from: 0x00))

    /// The install binding every column vector is sealed under: `A7` × 16
    /// (`MeshSessionStoreFixtures.installA`).
    static let installBinding = Data(repeating: 0xA7, count: 16)

    /// HKDF-SHA256(`columnContentKey`, no salt, info `fernlet.mesh.session-context.v1`, 32).
    static let sessionColumnKeyHex = "05140c847fcf2310de39159e6bb63f15bdc45e2cbefca852babff8f641651a3c"

    /// HKDF-SHA256(`columnContentKey`, no salt, info `fernlet.mesh.routed-store.v1`, 32).
    static let routedColumnKeyHex = "88abbc36629412d103e0ab8a725996a367ced7c8456875d5381f1a5dabca30d3"

    /// V3 column blob, 39 bytes: `03` ‖ nonce `00…0b` ‖ ChaChaPoly(`["golden"]`) under the session
    /// column key with AAD `fernlet.mesh.session-context.v1` ‖ binding (crypto census §3.6).
    static let sessionColumnBlobHex = "03000102030405060708090a0ba1920d28007bc19c37b8ae79712f2be189cb51a4e38fc8a5b9e2"

    /// The same for `fernlet.mesh.routed-store.v1` (crypto census §3.6).
    static let routedColumnBlobHex = "03000102030405060708090a0b86a641157982173490f36a963d95d5f07342b61df00b128c113d"

    /// V3 blob, 49 bytes, nonce `10…1b`, plaintext `{"schemaVersion":99}` — a schema no build owns, so
    /// a store that reports 99 decrypted the bytes to read it. Session-context column.
    static let sessionStoreBlobHex =
        "03101112131415161718191a1b02d56166eff260f5e0ceb25e3bbcb65e1aa7ef61e86e252d842b2e01bcb2f933a73d21c8"

    /// The same plaintext and nonce under the routed-store column.
    static let routedStoreBlobHex =
        "03101112131415161718191a1ba4b8aa18f252b912c70bc5b06ff23ff5ed39af15f1fc28e5f303e00fb15bfd7a07f2456a"

    /// X25519 public key of the planted key-agreement key `60…7f`.
    static let plantedKeyAgreementPublicKeyHex = "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f"

    /// `FGK2` group-key wrap to the planted key, 96 bytes: `FGK2` ‖ ephemeral public key (private
    /// `80…9f`) ‖ nonce `c0…cb` ‖ AES-256-GCM(group key `e0…ff`) under HKDF salt
    /// `fernlet.mesh.groupkey.v1` (info = ephemeral ‖ recipient) with AAD `fernlet.mesh.groupkey.wrap.aead.v2`.
    static let groupKeyWrapHex = "46474b32493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531dc0c1c2c3c4c5"
        + "c6c7c8c9cacbf5404ca8b35cf9c1794714bddf1960341a9d64f4b340a0b9b13b332933365a352ade1f485918499a370460a36ba60186"

    /// The X25519 public key of the transport vector's sender static key `20…3f`.
    static let transportSenderPublicKeyHex = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"

    /// `FPT2` transport seal to the planted key, 92 bytes: `FPT2` ‖ ephemeral public key (private
    /// `a0…bf`) ‖ ChaChaPoly(`fernlet golden transport`, nonce `d0…db`) under HKDF salt
    /// `fernlet.proximity.v1` (info = sender ‖ recipient) with AAD
    /// `fernlet.proximity.transport.aead.v2` ‖ sender.
    static let transportSealHex = "46505432605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23cd0d1d2d3d4d5"
        + "d6d7d8d9dadb66bf51abaace59e289c9dab60d9c402168eaa30ac8eb11e4cff88a3ab81b6dd2891b642f0cce9d4c"

    /// The routed wrap's recipient public key (private `30…4f`) and ephemeral public key (private `90…af`).
    static let routedRecipientPublicKeyHex = "34e42d4af5ef94a07a3a84201b889d4cd1a743cb27b11b6a10438a8feb8e5847"
    static let routedEphemeralPublicKeyHex = "9fd7ad6dcff4298dd3f96d5b1b2af910a0535b1488d7f8fabb349a982880b615"

    /// The routed per-recipient wrap of content key `10…2f`: AES-256-GCM, nonce `b0…bb`, under HKDF
    /// salt `fernlet.mesh.routed.content-key.v1` (info = ephemeral ‖ recipient), with the AAD
    /// `MeshRoutedManifestGoldenTests.goldenWrapAADHex` pins (mesh `1F1F…`, item `5A5A…`, `fp001` → `fp002`).
    static let routedSealedKeyHex = "c8c9ae877144ea9ef3d40b5e4c7961d9a4164d6f15cbaff16ee377cdaaaf4e58"
        + "852ff83c5ea99c35050d4196b41654bc"

    /// One mesh column's vectors, with today's accessor for its purpose.
    private struct ColumnVector {
        let name: String
        let purpose: CryptographicPurpose
        let columnKeyHex: String
        let blobHex: String
    }

    /// The two mesh columns.
    private static var columnVectors: [ColumnVector] {
        [
            ColumnVector(name: "session-context", purpose: FernletCryptoPurpose.KeyDerivation.meshSessionContextV1,
                         columnKeyHex: sessionColumnKeyHex, blobHex: sessionColumnBlobHex),
            ColumnVector(name: "routed-store", purpose: FernletCryptoPurpose.KeyDerivation.meshRoutedStoreV1,
                         columnKeyHex: routedColumnKeyHex, blobHex: routedColumnBlobHex)
        ]
    }

    /// The two mesh column keys: salt-free HKDF with the label as `info`.
    @Test func theTwoMeshColumnKeysAreTheirKnownAnswers() {
        // R2: bounded by the two columns.
        for vector in Self.columnVectors {
            let key = ColumnCrypto.deriveColumnKey(contentKey: Self.columnContentKey, purpose: vector.purpose,
                                                   outputByteCount: 32)
            let actual = Self.hex(key.withUnsafeBytes { Data($0) })
            #expect(actual == vector.columnKeyHex, "\(vector.name) column key moved — actual hex = \(actual)")
        }
    }

    /// A V3 blob built from the literal label opens under each column's purpose and the pinned binding:
    /// the label is the HKDF `info` AND the front of the AAD, in that order.
    @Test func theTwoKnownColumnBlobsOpenUnderTheirPurposes() throws {
        try DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            // R2: bounded by the two columns.
            for vector in Self.columnVectors {
                let blob = try #require(Self.bytes(hex: vector.blobHex))
                #expect(blob.first == 0x03)
                let opened: [String]? = try ColumnCrypto(purpose: vector.purpose).open(blob, contentKey: Self.columnContentKey)
                #expect(opened == ["golden"], "the \(vector.name) column did not open its known blob")
            }
        }
    }

    /// The session store, on an isolated scope, opens a blob planted at the frozen file name under a
    /// seal key planted at the frozen account — so the store's file name, its seal-key account, its
    /// column purpose and the binding's place in the AAD are all pinned by one load. Since step A0.2.8
    /// the scope carries `.fernlet`, whose names the store reads, and since step A0.2.9 Fernlet's
    /// install-binding adapter, through which the pinned binding reaches the store's column seal.
    @Test func theSessionStoreOpensItsKnownBlobUnderItsFrozenNames() throws {
        let scope = MeshSessionStorageScope(
            namespace: .fernlet,
            directory: Self.scratchDirectory(),
            keychainService: "com.fernlet.mesh-session.test.namespacegolden.\(UUID().uuidString)",
            installBinding: FernletDeviceBindingAdapter()
        )
        defer {
            MeshSessionStore.wipeForDeleteAll(scope: scope)
            try? FileManager.default.removeItem(at: scope.directory)
        }
        Self.plantSealKey(account: Self.frozen("installation.keychain.meshSessionSealKey.account"),
                          service: scope.keychainService)
        try Self.writeBlob(Self.sessionStoreBlobHex, named: Self.frozen("installation.storage.meshSessionContextFileName"),
                           in: scope.directory)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            MeshSessionStore(scope: scope).load()
        }
        guard case .corrupt(let corruption) = load, case .unsupportedSchemaVersion(let version) = corruption.detail else {
            Issue.record("the session store did not decrypt its known blob at its frozen names: \(load)")
            return
        }
        #expect(version == 99)
    }

    /// The routed store, likewise: its index file name, seal-key account and column purpose by one
    /// load, and its chunk directory by the path it composes.
    @Test func theRoutedStoreOpensItsKnownBlobUnderItsFrozenNames() throws {
        let scope = MeshRoutedStorageScope(
            namespace: .fernlet,
            directory: Self.scratchDirectory(),
            keychainService: "com.fernlet.mesh-routed.test.namespacegolden.\(UUID().uuidString)",
            installBinding: FernletDeviceBindingAdapter()
        )
        defer {
            MeshRoutedStore.wipeForDeleteAll(scope: scope)
            try? FileManager.default.removeItem(at: scope.directory)
        }
        Self.plantSealKey(account: Self.frozen("installation.keychain.meshRoutedSealKey.account"),
                          service: scope.keychainService)
        try Self.writeBlob(Self.routedStoreBlobHex, named: Self.frozen("installation.storage.meshRoutedIndexFileName"),
                           in: scope.directory)

        let store = MeshRoutedStore(scope: scope)
        let chunks = scope.directory.appendingPathComponent(
            Self.frozen("installation.storage.meshRoutedChunkDirectoryName"), isDirectory: true)
        #expect(store.chunkDirectory == chunks, "the routed store keeps its chunks at \(store.chunkDirectory.path)")
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) { store.load() }
        guard case .corrupt(let corruption) = load, case .unsupportedSchemaVersion(let version) = corruption.detail else {
            Issue.record("the routed store did not decrypt its known blob at its frozen names: \(load)")
            return
        }
        #expect(version == 99)
    }

    /// The group-key wrap: an `FGK2` blob built from the literal salt and AAD opens to its known key in
    /// the real `decryptGroupKey`, over an identity planted at the frozen account names.
    @Test func aLiteralBuiltGroupKeyWrapOpensToItsKnownKey() throws {
        let planted = try Self.plantedIdentity()
        defer { KeychainItem.deleteAll(service: planted.service) }
        let wrap = try #require(Self.bytes(hex: Self.groupKeyWrapHex))
        do {
            let opened = try planted.identity.decryptGroupKey(wrap)
            #expect(opened == Self.sequence(from: 0xE0), "the FGK2 wrap opened to \(Self.hex(opened))")
        } catch {
            Issue.record("production refused the literal-built FGK2 wrap (\(error)): its salt, AAD or marker moved")
        }
    }

    /// The transport seal: an `FPT2` blob built from the literal salt and AAD opens to its known
    /// plaintext in the real `open`, over the same planted identity.
    @Test func aLiteralBuiltTransportSealOpensToItsKnownPlaintext() throws {
        let planted = try Self.plantedIdentity()
        defer { KeychainItem.deleteAll(service: planted.service) }
        let sealed = try #require(Self.bytes(hex: Self.transportSealHex))
        let sender = try #require(Self.bytes(hex: Self.transportSenderPublicKeyHex))
        do {
            let opened = try planted.identity.open(sealed, from: sender)
            #expect(opened == Data("fernlet golden transport".utf8), "the FPT2 seal opened to \(Self.hex(opened))")
        } catch {
            Issue.record("production refused the literal-built FPT2 seal (\(error)): its salt, AAD or marker moved")
        }
    }

    /// The routed per-recipient key wrap opens to its known content key in the real `unwrap`. The
    /// recipient's static agreement is a closure, so no keychain is involved.
    @Test func aLiteralBuiltRoutedContentKeyWrapOpensToItsKnownKey() throws {
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.sequence(from: 0x30))
        #expect(Self.hex(recipient.publicKey.rawRepresentation) == Self.routedRecipientPublicKeyHex)
        let wrap = MeshRecipientKeyWrap(
            recipientFingerprint: "fp002",
            ephemeralPublicKey: try #require(Self.bytes(hex: Self.routedEphemeralPublicKeyHex)),
            nonce: Self.sequence(from: 0xB0, count: 12),
            sealedKey: try #require(Self.bytes(hex: Self.routedSealedKeyHex))
        )
        let binding = MeshRoutedWrapBinding(
            meshID: try #require(UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")),
            itemID: try #require(UUID(uuidString: "5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E")),
            originFingerprint: "fp001"
        )
        do {
            let opened = try MeshRoutedContentKeyWrapper.unwrap(
                wrap, binding: binding, localFingerprint: "fp002",
                localKeyAgreementPublicKey: recipient.publicKey.rawRepresentation,
                staticAgreement: { try recipient.sharedSecretFromKeyAgreement(
                    with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)) },
                in: .fernlet
            )
            #expect(opened == Self.sequence(from: 0x10), "the routed wrap opened to \(Self.hex(opened))")
        } catch {
            Issue.record("production refused the literal-built routed key wrap (\(error)): its salt or AAD moved")
        }
    }

    /// The closed-mode metadata door: a wrapper built from the literal `FMGM2` marker and the literal
    /// AAD opens under the joined mesh's group key and is dispatched — the descriptor inside it renames
    /// the mesh. `decryptPayload` is private, so the manager's own inbound door is the way in.
    ///
    /// The control is the same frame sealed under the group-key-wrap label and stamped LATER, so it
    /// would win the name if it opened: a door keyed to that neighbouring label ends on "Refused",
    /// and one keyed to any other label, or to none, stays on "Before".
    @Test func aLiteralBuiltMetadataWrapperOpensUnderTheGroupKey() async throws {
        let store = makeTestStore()
        defer { withExtendedLifetime(store) {} }   // `MeshNetworkManager.store` is `unowned`
        let manager = MeshNetworkManager(store: store)
        let coordinator = Self.unprovisionedCoordinator()
        manager.addSlotForTesting(coordinator: coordinator,
                                  peer: PeerHandle(id: UUID(), displayHint: "Member", discoveryInfo: nil,
                                                   advertisedFingerprint: nil),
                                  fingerprint: "fp-member")
        let admitterService = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: admitterService) }
        let admitter = IdentityService(namespace: .fernlet, keychainService: admitterService)
        try admitter.ensureProvisioned()
        let groupKey = Self.sequence(from: 0x70)
        let mesh = try Self.join(manager, on: coordinator, admitter: admitter, groupKey: groupKey, epoch: 5)
        #expect(manager.currentGroupKey?.keyBytes == groupKey, "precondition: the join installed the group key")

        let control = Self.renamed(mesh, to: "Refused", secondsLater: 2)
        try Self.deliverMetadata(control, label: Self.frozen("family.purposes.aead.meshGroupKeyWrapV2"),
                                 groupKey: groupKey, nonce: Self.sequence(from: 0x5C, count: 12), epoch: 5,
                                 to: manager, on: coordinator)
        let golden = Self.renamed(mesh, to: "Golden", secondsLater: 1)
        try Self.deliverMetadata(golden, label: Self.frozen("family.purposes.aead.meshEncryptedMetadataV2"),
                                 groupKey: groupKey, nonce: Self.sequence(from: 0x50, count: 12), epoch: 5,
                                 to: manager, on: coordinator)

        await Self.waitUntil { manager.currentMesh?.name == "Golden" }
        // Both handlers run as spawned tasks; let them drain so a late open of the control would show.
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.currentMesh?.name == "Golden", """
            the metadata door did not open the literal-built FMGM2 wrapper, or opened the control: the \
            mesh is named \(manager.currentMesh?.name ?? "nothing")
            """)
    }

    // MARK: Group 3 — transcripts, epoch ids and the tokens spelled like labels

    /// `lp(fernlet.mesh.channel-introduction.v1)`: the 8-byte length, then the label.
    static let channelIntroductionPrefixHex =
        "00000000000000246665726e6c65742e6d6573682e6368616e6e656c2d696e74726f64756374696f6e2e7631"

    /// `fernlet.verify.qr.v1` raw, then the version byte `01`.
    static let verifyQRPrefixHex = "6665726e6c65742e7665726966792e71722e763101"

    /// `fernlet.verify.response.v1` raw, then the scanner key's first byte (`44` in the fixture).
    static let verifyResponsePrefixHex = "6665726e6c65742e7665726966792e726573706f6e73652e763144"

    /// The channel introduction transcript opens with its label LENGTH-PREFIXED, and the registry
    /// purpose accepts it.
    @Test func theChannelIntroductionTranscriptOpensWithItsFramedLabel() throws {
        let transcript = canonicalBytes(for: MeshChannelIntroductionTranscript(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion,
            meshID: try #require(UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")),
            epochRef: "7",
            initiatorSigningPublicKey: Data(repeating: 0x06, count: 32),
            responderSigningPublicKey: Data(repeating: 0x07, count: 32),
            initiatorNonce: Data(repeating: 0x08, count: 16),
            responderNonce: Data(repeating: 0x09, count: 16),
            channelBindingHash: Data(repeating: 0x0A, count: 32)
        ), in: .fernlet)
        let prefix = try #require(Self.bytes(hex: Self.channelIntroductionPrefixHex))
        #expect(transcript.count > prefix.count)
        #expect(transcript.prefix(prefix.count) == prefix,
                "actual prefix hex = \(Self.hex(transcript.prefix(prefix.count)))")
        #expect(FernletCryptoPurpose.Signature.meshChannelIntroductionV1.signingBytes(transcript) != nil)
    }

    /// The verify QR transcript opens with its label RAW, the version byte straight after it, and is
    /// exactly 109 bytes: label 20 ‖ version 1 ‖ two keys 64 ‖ timestamp 8 ‖ nonce 16.
    @Test func theVerifyQRTranscriptOpensWithItsRawLabel() throws {
        let transcript = ProximityVerifyQR.canonicalBytes(
            version: 1,
            signingPublicKey: Data(repeating: 0x11, count: 32),
            keyAgreementPublicKey: Data(repeating: 0x22, count: 32),
            timestamp: 1_700_000_000,
            nonce: Data(repeating: 0x33, count: 16),
            in: .fernlet
        )
        let prefix = try #require(Self.bytes(hex: Self.verifyQRPrefixHex))
        #expect(transcript.prefix(prefix.count) == prefix,
                "actual prefix hex = \(Self.hex(transcript.prefix(prefix.count)))")
        #expect(transcript.count == 109, "the QR transcript is \(transcript.count) bytes")
        #expect(FernletCryptoPurpose.Signature.proximityQRIdentityV1.signingBytes(transcript) != nil)
    }

    /// The verify response transcript opens with its label RAW, the scanner's key straight after it,
    /// and is exactly 90 bytes: label 26 ‖ scanner key 32 ‖ two nonces 32.
    @Test func theVerifyResponseTranscriptOpensWithItsRawLabel() throws {
        let transcript = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: Data(repeating: 0x44, count: 32),
            challengeNonce: Data(repeating: 0x55, count: 16),
            qrNonce: Data(repeating: 0x66, count: 16),
            in: .fernlet
        )
        let prefix = try #require(Self.bytes(hex: Self.verifyResponsePrefixHex))
        #expect(transcript.prefix(prefix.count) == prefix,
                "actual prefix hex = \(Self.hex(transcript.prefix(prefix.count)))")
        #expect(transcript.count == 90, "the response transcript is \(transcript.count) bytes")
        #expect(FernletCryptoPurpose.Signature.proximityQRResponseV1.signingBytes(transcript) != nil)
    }

    /// The two epoch ids `MeshMembershipEventGoldenTests.goldenEpochHeadsHex` embeds, pinned on their
    /// own: SHA-256 over the RAW epoch domain ‖ lowercase mesh id ‖ u32 counter ‖ fingerprint, first 16
    /// bytes. A length-prefixed domain, or another label, moves both.
    @Test func theEpochIDsAreTheirKnownAnswers() throws {
        let meshID = try #require(UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B"))
        let first = try #require(MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000aa", meshID: meshID,
                                                     in: .fernlet))
        let second = try #require(MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000bb", meshID: meshID,
                                                      in: .fernlet))
        let firstID = first.epochID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secondID = second.epochID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        #expect(firstID == "355c877a3834ff2b9b86b074fccaf2e7", "actual epoch id = \(firstID)")
        #expect(secondID == "da5a41f47fff542d2acaf1260ab01d31", "actual epoch id = \(secondID)")
        #expect(first.canonicalString == "7.355c877a3834ff2b9b86b074fccaf2e7.00000000000000aa")
    }

    /// The wire tokens spelled exactly like a signature label — fifteen of `.fernlet`'s mesh messages,
    /// the tokens the mesh manager signs those frames under, and three of its membership record kinds
    /// — still equal the frozen label. The key-agreement and verify-response tokens had no such pin
    /// before this suite. The fourth record kind equals no label; it is hashed into the signed
    /// inventory digest, so it is pinned by literal beside them.
    ///
    /// Two at-rest format names join them as literal rows since step A0.2.8, which deleted the unused
    /// mirror tokens that spelled them (`MeshSessionContextSchema.token`, `MeshRoutedIndexSchema.token`,
    /// pinned until then in MeshKeyAgreementAdvertisementTests and MeshRoutedStoreTests): each named
    /// its sealed file's format exactly as its store's column-seal label, so a file's format and its
    /// key derivation stay one vocabulary.
    @Test func theWireTokensSpelledLikeALabelStillEqualIt() {
        let signature = "family.purposes.signature."
        let kinds = ProximityNamespace.fernlet.family.vocabulary.membershipRecordKinds
        let mesh = ProximityNamespace.fernlet.family.vocabulary.mesh
        let vocabulary: [(token: String, spelling: String, label: String)] = [
            ("mesh.verifyResponse", mesh.verifyResponse, "proximityQRResponseV1"),
            ("mesh.keyAgreement", mesh.keyAgreement, "meshKeyAgreementV1"),
            ("mesh.memberDeparture", mesh.memberDeparture, "meshMemberDepartureV1"),
            ("mesh.memberRemoval", mesh.memberRemoval, "meshMemberRemovalV1"),
            ("mesh.terminated", mesh.terminated, "meshTerminatedV1"),
            ("mesh.inventoryDigest", mesh.inventoryDigest, "meshInventoryDigestV1"),
            ("mesh.epochHeads", mesh.epochHeads, "meshEpochHeadsV1"),
            ("mesh.removalProposalSigned", mesh.removalProposalSigned, "meshRemovalProposalV1"),
            ("mesh.removalVote", mesh.removalVote, "meshRemovalVoteV1"),
            ("mesh.routedManifest", mesh.routedManifest, "meshRoutedManifestV1"),
            ("mesh.routedChunk", mesh.routedChunk, "meshRoutedChunkV1"),
            ("mesh.custodyReceipt", mesh.custodyReceipt, "meshCustodyReceiptV1"),
            ("mesh.recipientReceipt", mesh.recipientReceipt, "meshRecipientReceiptV1"),
            ("mesh.routedInventoryDigest", mesh.routedInventoryDigest, "meshRoutedInventoryDigestV1"),
            ("mesh.routedDrainAnswer", mesh.routedDrainAnswer, "meshRoutedDrainAnswerV1"),
            ("membershipRecordKinds.departure", kinds.departure, "meshMemberDepartureV1"),
            ("membershipRecordKinds.removal", kinds.removal, "meshMemberRemovalV1"),
            ("membershipRecordKinds.termination", kinds.termination, "meshTerminatedV1")
        ]
        #expect(vocabulary.count == 18)
        // R2: bounded by the eighteen tokens.
        for entry in vocabulary {
            let frozen = Self.frozen(signature + entry.label)
            #expect(entry.spelling == frozen, "\(entry.token) is \(entry.spelling); the label it equals is \(frozen)")
        }
        #expect(kinds.admission == "fernlet.mesh.member-admission.v1",
                "the admission record kind moved: \(kinds.admission)")

        let retiredAtRestTokens: [(token: String, spelling: String, label: String)] = [
            ("MeshSessionContextSchema.token", "fernlet.mesh.session-context.v1", "meshSessionContextV1"),
            ("MeshRoutedIndexSchema.token", "fernlet.mesh.routed-store.v1", "meshRoutedStoreV1")
        ]
        // R2: bounded by the two retired tokens.
        for entry in retiredAtRestTokens {
            let frozen = Self.frozen("family.purposes.keyDerivation." + entry.label)
            #expect(entry.spelling == frozen, "\(entry.token) was \(entry.spelling); the column seal it mirrored is \(frozen)")
        }
    }

    // MARK: Group 4 — the format constants that stay ProximityKit's

    /// The markers, the column byte and the two extensions, by their constants where a test can name
    /// one, and by what the production writers stamp where the constant is private (`FPT2`, `FGK2`).
    /// `FMGM2` has no writer left; ``aLiteralBuiltMetadataWrapperOpensUnderTheGroupKey()`` pins its reader.
    @Test func theFormatConstantsKeepTheirBytes() throws {
        #expect(MeshRoutedItemSealFormat.marker == Data("FMRI1".utf8))
        #expect(ColumnCrypto.deviceBoundFormatVersionV3 == 0x03)
        #expect(MeshSessionStore.quarantineExtension == "corrupt")
        #expect(MeshRoutedStore.quarantineExtension == "corrupt")
        #expect(MeshRoutedStore.chunkFileExtension == "chunk")
        #expect(URL(fileURLWithPath: MeshRoutedStore.newChunkFileName()).pathExtension == "chunk")

        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        let sealed = try identity.seal(Data("marker".utf8), to: identity.localKeyAgreementPublicKey)
        #expect(sealed.prefix(4) == Data("FPT2".utf8), "the transport seal starts \(Self.hex(sealed.prefix(4)))")
        let wrapped = try identity.encryptGroupKey(Self.sequence(from: 0xE0), for: identity.localKeyAgreementPublicKey)
        #expect(wrapped.prefix(4) == Data("FGK2".utf8), "the group-key wrap starts \(Self.hex(wrapped.prefix(4)))")
        #expect(wrapped.count == 96)
    }

    /// The verify QR's URL: scheme, host, the one query key `d` and payload version 1. A URL written
    /// by hand from those spellings parses, and the payload it carries is version 1 and valid.
    @Test func theVerifyQRURLKeepsItsHostQueryKeyAndVersion() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let made = try ProximityVerifyQR.makeURL(identity: identity, now: now)
        let components = try #require(URLComponents(url: made.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "fernlet")
        #expect(components.host == "verify")
        #expect(components.queryItems?.map(\.name) == ["d"])
        let encoded = try #require(components.queryItems?.first?.value)
        let handBuilt = try #require(URL(string: "fernlet://verify?d=" + encoded))
        let payload = try #require(ProximityVerifyQR.parse(handBuilt, in: .fernlet), "a hand-built verify URL no longer parses")
        #expect(payload.version == 1)
        #expect(ProximityVerifyQR.isValid(payload, at: now, in: .fernlet))
    }

    // MARK: Group 5 — `.fernlet` against the table (A0.2.2)

    /// The QR host's row: a ProximityKit format constant beside the scheme, not a namespace value.
    static let qrHostField = "proximityKit.verifyQR.urlHost"

    /// The one label FernletCrypto's registry does not declare: the epoch id's domain.
    static let epochField = "family.purposes.hash.meshEpochIDV1"

    /// `.fernlet`'s bytes for every namespace field the table pins, read straight off the value
    /// FernletConnections ships: the labels through `labelRows`, everything else by its own accessor.
    static var fernletValues: [String: Data] {
        let namespace = ProximityNamespace.fernlet
        let radios = namespace.family.radios
        let keychain = namespace.installation.keychain
        let storage = namespace.installation.storage
        let text: [String: String] = [
            "family.radios.mesh.serviceType": radios.mesh.serviceType,
            "family.radios.mesh.alpn": radios.mesh.alpn,
            "family.radios.presence.serviceType": radios.presence.serviceType,
            "family.radios.presence.alpn": radios.presence.alpn,
            "family.radios.recipeShare.serviceType": radios.recipeShare.serviceType,
            "family.radios.recipeShare.alpn": radios.recipeShare.alpn,
            "family.verifyQR.urlScheme": namespace.family.verifyQR.urlScheme,
            "installation.keychain.identity.service": keychain.identity.service,
            "installation.keychain.identity.signingPrivateKey": keychain.identity.signingPrivateKey,
            "installation.keychain.identity.keyAgreementPrivateKey": keychain.identity.keyAgreementPrivateKey,
            "installation.keychain.identity.signingPublicKeyCache": keychain.identity.signingPublicKeyCache,
            "installation.keychain.identity.keyAgreementPublicKeyCache": keychain.identity.keyAgreementPublicKeyCache,
            "installation.keychain.meshSessionSealKey.service": keychain.meshSessionSealKey.service,
            "installation.keychain.meshSessionSealKey.account": keychain.meshSessionSealKey.account,
            "installation.keychain.meshRoutedSealKey.service": keychain.meshRoutedSealKey.service,
            "installation.keychain.meshRoutedSealKey.account": keychain.meshRoutedSealKey.account,
            "installation.storage.directoryName": storage.directoryName,
            "installation.storage.meshSessionContextFileName": storage.meshSessionContextFileName,
            "installation.storage.meshRoutedIndexFileName": storage.meshRoutedIndexFileName,
            "installation.storage.meshRoutedChunkDirectoryName": storage.meshRoutedChunkDirectoryName,
            "installation.logSubsystem": namespace.installation.logSubsystem
        ]
        var values = text.mapValues { Data($0.utf8) }
        values["family.radios.meshHeartbeat"] = radios.meshHeartbeat
        // R2: bounded by the 41 label rows.
        for row in namespace.labelRows {
            values[row.field] = row.purpose.data
        }
        return values
    }

    /// The value FernletConnections ships IS the literal column: exactly the table's 63 namespace
    /// fields, each equal to its frozen literal byte for byte, and the labels in the table's order.
    @Test func everyFernletValueIsItsFrozenLiteral() {
        let values = Self.fernletValues
        let rows = Self.table.filter { $0.field != Self.qrHostField }
        #expect(rows.count == 63, "the table holds \(rows.count) namespace values besides the QR host")
        #expect(values.count == 63, "`.fernlet` was read for \(values.count) fields")
        let unpinned = Set(values.keys).subtracting(rows.map(\.field)).sorted()
        let unread = Set(rows.map(\.field)).subtracting(values.keys).sorted()
        #expect(unpinned.isEmpty && unread.isEmpty, "no frozen row for \(unpinned); never read off `.fernlet`: \(unread)")
        // R2: bounded by the table.
        for row in rows {
            guard let actual = values[row.field] else { continue }
            #expect(actual == Data(row.frozen.utf8), """
                ProximityNamespace.fernlet's \(row.field) is "\(String(decoding: actual, as: UTF8.self))" \
                (\(Self.hex(actual))); its frozen literal is "\(row.frozen)". The literal never moves: \
                fix FernletProtocolNamespace.swift.
                """)
        }
        let labelFields = Self.table.filter { $0.group == .label }.map(\.field)
        #expect(ProximityNamespace.fernlet.labelRows.map(\.field) == labelFields,
                "`labelRows` lists the labels in another order than the table")
    }

    /// The role ProximityKit fixes for `field`, as the design assigns it (every declared feature
    /// salt's is `.keyDerivationSalt`), or nil for a field the design does not have.
    private static func designedRole(of field: String) -> ProximityCryptographicPurpose.Role? {
        let signature = "family.purposes.signature."
        let keyDerivation = "family.purposes.keyDerivation."
        switch field {
        case signature + "proximityQRIdentityV1", signature + "proximityQRResponseV1":
            return .signature(.rawPrefix)
        case signature + "legacyV1.identityEnvelopeV1", signature + "legacyV1.meshAdmissionTokenV1":
            return .signature(.absent)
        case keyDerivation + "meshTLSExporterV1":
            return .tlsExporterLabel
        case keyDerivation + "meshSessionContextV1", keyDerivation + "meshRoutedStoreV1":
            return .columnSeal
        case epochField:
            return .hashDomain(.rawPrefix)
        default:
            break
        }
        if field.hasPrefix(signature) { return .signature(.lengthPrefixed) }
        if field.hasPrefix(keyDerivation) { return .keyDerivationSalt }
        if field.hasPrefix("family.purposes.aead.") { return .aeadAssociatedData }
        if field.hasPrefix("family.purposes.hash.") { return .hashDomain(.lengthPrefixed) }
        if field.hasPrefix("family.purposes.feature.") { return .keyDerivationSalt }
        return nil
    }

    /// Every `.fernlet` label carries the role its field fixes: the 17 canonical transcripts
    /// length-prefixed, the two QR transcripts raw, the legacy pair verify-only, five salts (the
    /// protocol's three and the two feature salts it declares), the exporter label, two column seals,
    /// five AADs, the six mesh hashes length-prefixed (as ProximityKit consumes them, not as
    /// FernletCrypto declares them) and the epoch domain raw.
    @Test func everyFernletLabelCarriesTheRoleItsFieldFixes() {
        let rows = ProximityNamespace.fernlet.labelRows
        #expect(rows.count == 41, "`.fernlet` has \(rows.count) labels")
        // R2: bounded by the 41 label rows.
        for row in rows {
            #expect(row.purpose.role == Self.designedRole(of: row.field),
                    "\(row.field) has the role \(row.purpose.role), the design fixes \(String(describing: Self.designedRole(of: row.field)))")
        }
        let tally = Dictionary(grouping: rows, by: { $0.purpose.role }).mapValues(\.count)
        let designed: [ProximityCryptographicPurpose.Role: Int] = [
            .signature(.lengthPrefixed): 17, .signature(.rawPrefix): 2, .signature(.absent): 2,
            .keyDerivationSalt: 5, .tlsExporterLabel: 1, .columnSeal: 2, .aeadAssociatedData: 5,
            .hashDomain(.lengthPrefixed): 6, .hashDomain(.rawPrefix): 1
        ]
        #expect(tally == designed, "the roles tally \(tally), the design \(designed)")
    }

    /// `.fernlet` passes every soundness rule, and `validated` hands the same value back.
    @Test func theFernletNamespaceIsSound() throws {
        #expect(ProximityNamespace.fernlet.soundness == .sound,
                "ProximityNamespace.fernlet is unsound: \(ProximityNamespace.fernlet.soundness)")
        let validated = try ProximityNamespace.validated(family: .fernlet, installation: .fernletApp)
        #expect(validated == ProximityNamespace.fernlet)
    }

    /// FernletCrypto's 38 core registry entries and the two feature salts' entries, each beside the
    /// `.fernlet` field that twins it.
    ///
    /// Written out by hand: the table's `today:` column is the one later commits re-point at the
    /// namespace itself, so it cannot double as the registry side of this comparison.
    static var registryTwins: [(field: String, twin: CryptographicPurpose)] {
        typealias Signature = FernletCryptoPurpose.Signature
        typealias KeyDerivation = FernletCryptoPurpose.KeyDerivation
        typealias AEAD = FernletCryptoPurpose.AEAD
        typealias Hash = FernletCryptoPurpose.Hash
        let signature = "family.purposes.signature."
        let derivation = "family.purposes.keyDerivation."
        let aead = "family.purposes.aead."
        let hash = "family.purposes.hash."
        let feature = "family.purposes.feature."
        return [
            (signature + "identityEnvelopeV2", Signature.identityEnvelopeV2),
            (signature + "meshAdmissionTokenV2", Signature.meshAdmissionTokenV2),
            (signature + "meshChannelIntroductionV1", Signature.meshChannelIntroductionV1),
            (signature + "meshMemberDepartureV1", Signature.meshMemberDepartureV1),
            (signature + "meshMemberRemovalV1", Signature.meshMemberRemovalV1),
            (signature + "meshTerminatedV1", Signature.meshTerminatedV1),
            (signature + "meshInventoryDigestV1", Signature.meshInventoryDigestV1),
            (signature + "meshEpochHeadsV1", Signature.meshEpochHeadsV1),
            (signature + "meshRemovalProposalV1", Signature.meshRemovalProposalV1),
            (signature + "meshRemovalVoteV1", Signature.meshRemovalVoteV1),
            (signature + "meshKeyAgreementV1", Signature.meshKeyAgreementV1),
            (signature + "meshRoutedManifestV1", Signature.meshRoutedManifestV1),
            (signature + "meshRoutedChunkV1", Signature.meshRoutedChunkV1),
            (signature + "meshCustodyReceiptV1", Signature.meshCustodyReceiptV1),
            (signature + "meshRecipientReceiptV1", Signature.meshRecipientReceiptV1),
            (signature + "meshRoutedInventoryDigestV1", Signature.meshRoutedInventoryDigestV1),
            (signature + "meshRoutedDrainAnswerV1", Signature.meshRoutedDrainAnswerV1),
            (signature + "proximityQRIdentityV1", Signature.proximityQRIdentityV1),
            (signature + "proximityQRResponseV1", Signature.proximityQRResponseV1),
            (signature + "legacyV1.identityEnvelopeV1", Signature.identityEnvelopeLegacyV1),
            (signature + "legacyV1.meshAdmissionTokenV1", Signature.meshAdmissionTokenLegacyV1),
            (derivation + "proximityTransportV1", KeyDerivation.proximityTransportV1),
            (derivation + "meshGroupKeyWrapV1", KeyDerivation.meshGroupKeyWrapV1),
            (derivation + "meshTLSExporterV1", KeyDerivation.meshTLSExporterV1),
            (derivation + "meshRoutedContentKeyWrapV1", KeyDerivation.meshRoutedContentKeyWrapV1),
            (derivation + "meshSessionContextV1", KeyDerivation.meshSessionContextV1),
            (derivation + "meshRoutedStoreV1", KeyDerivation.meshRoutedStoreV1),
            (aead + "proximityTransportV2", AEAD.proximityTransportV2),
            (aead + "meshGroupKeyWrapV2", AEAD.meshGroupKeyWrapV2),
            (aead + "meshEncryptedMetadataV2", AEAD.meshEncryptedMetadataV2),
            (aead + "meshRoutedContentKeyWrapV1", AEAD.meshRoutedContentKeyWrapV1),
            (aead + "meshRoutedItemV1", AEAD.meshRoutedItemV1),
            (hash + "meshInventoryDigestV1", Hash.meshInventoryDigestV1),
            (hash + "meshRoutedContentV1", Hash.meshRoutedContentV1),
            (hash + "meshRoutedChunkV1", Hash.meshRoutedChunkV1),
            (hash + "meshRoutedChunkIDV1", Hash.meshRoutedChunkIDV1),
            (hash + "meshCustodyReceiptIDV1", Hash.meshCustodyReceiptIDV1),
            (hash + "meshRecipientReceiptIDV1", Hash.meshRecipientReceiptIDV1),
            (feature + "heartDropPairV1", KeyDerivation.heartDropPairV1),
            (feature + "presencePairV1", KeyDerivation.presencePairV1)
        ]
    }

    /// `.fernlet`'s labels by field. A repeated field keeps its first label rather than trapping; the
    /// roles and reflection cells are the ones that would report it.
    private static var fernletPurposes: [String: ProximityCryptographicPurpose] {
        Dictionary(ProximityNamespace.fernlet.labelRows.map { ($0.field, $0.purpose) }, uniquingKeysWith: { first, _ in first })
    }

    /// Each of FernletCrypto's 40 entries that `.fernlet` twins (its 38 core entries and the two
    /// feature salts) and its `.fernlet` twin are the same spelling, the same bytes. The twins retire
    /// at plan step C1; until then the two registries must not drift.
    @Test func everyCoreLabelIsSpelledLikeItsFernletCryptoTwin() {
        let twins = Self.registryTwins
        let purposes = Self.fernletPurposes
        #expect(twins.count == 40, "\(twins.count) twins listed")
        let twinFields = Set(twins.map(\.field))
        #expect(twinFields.count == 40, "a field is listed twice")
        #expect(twinFields == Set(purposes.keys).subtracting([Self.epochField]),
                "every `.fernlet` label but the epoch domain has a registry twin, and no other field does")
        // R2: bounded by the 40 twins.
        for entry in twins {
            guard let purpose = purposes[entry.field] else {
                Issue.record("`.fernlet` has no label at \(entry.field)")
                continue
            }
            #expect(purpose.rawValue == entry.twin.rawValue && purpose.data == entry.twin.data,
                    "\(entry.field) is \(purpose.rawValue); its FernletCrypto twin is \(entry.twin.rawValue)")
        }
    }

    /// Every signature twin, the legacy pair included, accepts exactly what its `.fernlet` twin
    /// accepts — over `lp(label) ‖ body`, `label ‖ body`, `body` and the empty input — and that is the
    /// acceptance the field's framing promises.
    @Test func everySignatureTwinAcceptsWhatItsFernletTwinAccepts() {
        let purposes = Self.fernletPurposes
        let body = Data("golden transcript body".utf8)
        var compared = 0
        // R2: bounded by the 40 twins.
        for entry in Self.registryTwins {
            guard let purpose = purposes[entry.field], case .signature(let framing) = purpose.role else { continue }
            compared += 1
            let inputs = [Self.lengthPrefixed(purpose.data) + body, purpose.data + body, body, Data()]
            let accepted = inputs.map { purpose.signingBytes($0) != nil }
            let twinAccepted = inputs.map { entry.twin.signingBytes($0) != nil }
            #expect(accepted == twinAccepted,
                    "\(entry.field) accepts \(accepted) of [lp+body, label+body, body, empty]; its twin \(twinAccepted)")
            let promised: [Bool]
            switch framing {
            case .lengthPrefixed: promised = [true, false, false, false]
            case .rawPrefix: promised = [false, true, false, false]
            case .absent: promised = [true, true, true, true]
            }
            #expect(accepted == promised, "\(entry.field) (\(framing)) accepts \(accepted), its framing promises \(promised)")
            // R2: bounded by the four inputs.
            for input in inputs where purpose.signingBytes(input) != nil {
                #expect(purpose.signingBytes(input) == input, "\(entry.field) changed the bytes it accepted")
            }
        }
        #expect(compared == 21, "\(compared) signature twins compared; the design has 17 + 2 + the legacy pair")
    }

    /// No label of FernletCrypto's 81 and `.fernlet`'s 41 together, deduplicated by bytes, is a byte
    /// prefix of another, but for the one pair CDST already argues safe (the two sealed-backup HKDF
    /// `info` labels). A ProximityKit label and an app label meet at every shared consumer from A0.2's
    /// routing on; this is CDST's rule run over both registries at once.
    @Test func noLabelOfTheRegistryAndFernletTogetherIsAPrefixOfAnother() {
        var names: [Data: String] = [:]
        // R2: bounded by the 81 registry entries.
        for domain in CryptographicDomainSeparationTests.allDomains where names[domain.purpose.data] == nil {
            names[domain.purpose.data] = "FernletCryptoPurpose.\(domain.name)"
        }
        #expect(names.count == 81, "the registry holds \(names.count) distinct labels")
        // R2: bounded by the 41 label rows.
        for row in ProximityNamespace.fernlet.labelRows where names[row.purpose.data] == nil {
            names[row.purpose.data] = ".fernlet \(row.field)"
        }
        #expect(names.count == 82, "together \(names.count) distinct labels; the 40 twins coincide and the epoch domain is new")
        let exceptions = CryptographicDomainSeparationTests.prefixExceptions
        var offenders: [String] = []
        var excused = 0
        // R2: bounded by the 82 × 82 label pairs.
        for (shorter, shorterName) in names {
            for (longer, longerName) in names where longer != shorter && longer.starts(with: shorter) {
                let pair = (String(decoding: shorter, as: UTF8.self), String(decoding: longer, as: UTF8.self))
                if exceptions.contains(where: { $0.shorter == pair.0 && $0.longer == pair.1 }) {
                    excused += 1
                } else {
                    offenders.append("\(shorterName) (\(pair.0)) prefixes \(longerName) (\(pair.1))")
                }
            }
        }
        #expect(offenders.isEmpty, "labels that are byte prefixes of another:\n\(offenders.sorted().joined(separator: "\n"))")
        #expect(excused == exceptions.count, "CDST's \(exceptions.count) prefix exception(s) matched \(excused) pair(s) here")
    }

    /// `labelRows` lists every label `.fernlet` stores, and nothing else stores one. Read by
    /// reflection over the WHOLE namespace, so a label added to any group, or anywhere else, without
    /// a row cannot slip past the prefix check above. The walk keeps labelled children only, so it
    /// finds the 39 fixed fields; the feature group keeps its declared salts as a list's entries, which
    /// `labelRows` lists after them, in their order.
    @Test func labelRowsCoverEveryLabelFieldOfFernlet() {
        let namespace = ProximityNamespace.fernlet
        var reflected: [(field: String, purpose: ProximityCryptographicPurpose)] = []
        var pending: [(path: String, value: Any)] = [(path: "", value: namespace)]
        var visits = 0
        // R2: at most 256 nodes; `.fernlet` has about 150 (its groups, 39 labels, its strings — the
        // thirty mesh messages among them — the vocabulary's sets and lists and the feature group's
        // entries, whose unlabeled members the walk skips, and the heartbeat's three mirror children),
        // and the check below fails if the walk is cut short.
        while visits < 256, let node = pending.popLast() {
            visits += 1
            if let purpose = node.value as? ProximityCryptographicPurpose {
                reflected.append((field: node.path, purpose: purpose))
                continue
            }
            let children = Mirror(reflecting: node.value).children.compactMap { child in
                child.label.map { (path: node.path.isEmpty ? $0 : node.path + "." + $0, value: child.value) }
            }
            pending.append(contentsOf: children.reversed())
        }
        #expect(pending.isEmpty, "the reflection walk stopped at \(visits) nodes with \(pending.count) left")
        #expect(reflected.count == 39, "reflection found \(reflected.count) labels in `.fernlet`'s fixed fields")
        let declared = namespace.family.purposes.feature.entries.map {
            (field: "family.purposes.feature." + $0.name, purpose: $0.purpose)
        }
        #expect(declared.count == 2, "`.fernlet` declares \(declared.count) feature salts")
        let stored = reflected + declared
        #expect(stored.map(\.field) == namespace.labelRows.map(\.field), "labelRows and the stored labels disagree")
        #expect(stored.map(\.purpose) == namespace.labelRows.map(\.purpose))
    }

    // MARK: Group 6 — every hash and transcript consumer against its field's role (A0.2.2)
    //
    // A role says how ProximityKit consumes a label; the consumer is the code that does it. Each cell
    // takes the bytes one production consumer writes TODAY and requires them to begin with the
    // `.fernlet` field's `prefixBytes`, so when A0.2's routing hands a consumer its field, a role and
    // the code that honours it cannot have drifted apart. Hash consumers hide their preimage behind
    // SHA-256, so their cells rebuild it as the field's prefix followed by the consumer's own tail
    // (written with the production writer) and require the production digest to match: only the
    // prefix is under test. The legacy pair has no writer, so no cell; its readers, the envelope's
    // and the admission token's verify, are pinned in group 9.
    //
    // Since step A0.2.4 a consumer that takes the namespace's labels is called here with `.fernlet`
    // spelled out (`in: .fernlet`), never through the test target's bindings: these cells pin values.
    //
    // Since step A0.2.6 the two authenticated-data builders whose labels it moved have a cell too:
    // their bytes are observable, so each opens with its field's raw prefix. The other AEAD and salt
    // consumers (the transport seal, the group-key wrap, the metadata door, the wrap's HKDF) keep
    // their bytes inside the primitive; group 2's literal-built blobs pin those, by opening.

    /// The signature labels of `.fernlet`.
    private static var signatures: ProximityNamespace.Signature { ProximityNamespace.fernlet.family.purposes.signature }

    /// The hash labels of `.fernlet`.
    private static var hashes: ProximityNamespace.Hash { ProximityNamespace.fernlet.family.purposes.hash }

    /// The AEAD labels of `.fernlet`.
    private static var aeads: ProximityNamespace.AEAD { ProximityNamespace.fernlet.family.purposes.aead }

    /// The canonical envelope opens with `lp(identityEnvelopeV2)`.
    @Test func theIdentityEnvelopeTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: Self.consumerEnvelope(), in: .fernlet), by: Self.signatures.identityEnvelopeV2,
                          consumer: "canonicalBytes(for: FernletIdentityEnvelope, in:)")
    }

    /// The canonical admission token opens with `lp(meshAdmissionTokenV2)`.
    @Test func theAdmissionTokenTranscriptBeginsWithItsFieldsPrefix() {
        let token = MeshAdmissionToken(
            meshID: MeshMembershipEventFixtures.meshID, joinerFingerprint: "fp-joiner",
            joinerSigningPublicKey: Data(repeating: 0x03, count: 32), admitterFingerprint: "fp-admitter",
            grantedAt: MeshMembershipEventFixtures.base, expiresAt: MeshMembershipEventFixtures.base.addingTimeInterval(3_600),
            admitterSigningPublicKey: Data(repeating: 0x04, count: 32), admitterSignature: Data())
        Self.expectFramed(canonicalBytes(for: token, in: .fernlet), by: Self.signatures.meshAdmissionTokenV2,
                          consumer: "canonicalBytes(for: MeshAdmissionToken, in:)")
    }

    /// The QUIC channel introduction opens with `lp(meshChannelIntroductionV1)`.
    @Test func theChannelIntroductionTranscriptBeginsWithItsFieldsPrefix() {
        let transcript = MeshChannelIntroductionTranscript(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion, meshID: MeshMembershipEventFixtures.meshID,
            epochRef: "7", initiatorSigningPublicKey: Data(repeating: 0x06, count: 32),
            responderSigningPublicKey: Data(repeating: 0x07, count: 32), initiatorNonce: Data(repeating: 0x08, count: 16),
            responderNonce: Data(repeating: 0x09, count: 16), channelBindingHash: Data(repeating: 0x0A, count: 32))
        Self.expectFramed(canonicalBytes(for: transcript, in: .fernlet), by: Self.signatures.meshChannelIntroductionV1,
                          consumer: "canonicalBytes(for: MeshChannelIntroductionTranscript, in:)")
    }

    /// A departure record opens with `lp(meshMemberDepartureV1)`.
    @Test func theDepartureTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.departure(), in: .fernlet),
                          by: Self.signatures.meshMemberDepartureV1, consumer: "canonicalBytes(for: SignedDepartureRecord, in:)")
    }

    /// A removal record opens with `lp(meshMemberRemovalV1)`.
    @Test func theRemovalTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.removal(), in: .fernlet),
                          by: Self.signatures.meshMemberRemovalV1, consumer: "canonicalBytes(for: SignedRemovalRecord, in:)")
    }

    /// A termination record opens with `lp(meshTerminatedV1)`.
    @Test func theTerminationTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.termination(), in: .fernlet),
                          by: Self.signatures.meshTerminatedV1, consumer: "canonicalBytes(for: SignedTerminationRecord, in:)")
    }

    /// The signed membership inventory digest opens with `lp(signature.meshInventoryDigestV1)`.
    @Test func theInventoryDigestTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload(), in: .fernlet),
                          by: Self.signatures.meshInventoryDigestV1, consumer: "canonicalBytes(for: MeshInventoryDigestPayload, in:)")
    }

    /// The epoch-heads message opens with `lp(meshEpochHeadsV1)`.
    @Test func theEpochHeadsTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.epochHeadsPayload(), in: .fernlet),
                          by: Self.signatures.meshEpochHeadsV1, consumer: "canonicalBytes(for: MeshEpochHeadsPayload, in:)")
    }

    /// A removal proposal opens with `lp(meshRemovalProposalV1)`.
    @Test func theRemovalProposalTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.removalProposal(), in: .fernlet),
                          by: Self.signatures.meshRemovalProposalV1, consumer: "canonicalBytes(for: SignedRemovalProposal, in:)")
    }

    /// A removal vote opens with `lp(meshRemovalVoteV1)`.
    @Test func theRemovalVoteTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.removalVote(), in: .fernlet),
                          by: Self.signatures.meshRemovalVoteV1, consumer: "canonicalBytes(for: SignedRemovalVote, in:)")
    }

    /// A key-agreement advertisement opens with `lp(meshKeyAgreementV1)`.
    @Test func theKeyAgreementTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshMembershipEventFixtures.keyAdvertisement(), in: .fernlet),
                          by: Self.signatures.meshKeyAgreementV1, consumer: "canonicalBytes(for: SignedKeyAgreementAdvertisement, in:)")
    }

    /// A routed manifest opens with `lp(meshRoutedManifestV1)`.
    @Test func theRoutedManifestTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshRoutedManifestFixtures.manifest(), in: .fernlet),
                          by: Self.signatures.meshRoutedManifestV1, consumer: "canonicalBytes(for: MeshRoutedManifest, in:)")
    }

    /// A routed chunk opens with `lp(signature.meshRoutedChunkV1)`.
    @Test func theRoutedChunkTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshChunkFixtures.chunk(), in: .fernlet), by: Self.signatures.meshRoutedChunkV1,
                          consumer: "canonicalBytes(for: MeshChunk, in:)")
    }

    /// A custody receipt opens with `lp(meshCustodyReceiptV1)`.
    @Test func theCustodyReceiptTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshCustodyReceiptFixtures.receipt(), in: .fernlet),
                          by: Self.signatures.meshCustodyReceiptV1, consumer: "canonicalBytes(for: MeshCustodyReceipt, in:)")
    }

    /// A recipient receipt opens with `lp(meshRecipientReceiptV1)`.
    @Test func theRecipientReceiptTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshRecipientReceiptFixtures.receipt(), in: .fernlet),
                          by: Self.signatures.meshRecipientReceiptV1, consumer: "canonicalBytes(for: MeshRecipientReceipt, in:)")
    }

    /// The routed inventory digest opens with `lp(meshRoutedInventoryDigestV1)`.
    @Test func theRoutedInventoryTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshRoutedInventoryFixtures.payload(), in: .fernlet),
                          by: Self.signatures.meshRoutedInventoryDigestV1,
                          consumer: "canonicalBytes(for: MeshRoutedInventoryPayload, in:)")
    }

    /// A routed drain answer opens with `lp(meshRoutedDrainAnswerV1)`.
    @Test func theRoutedDrainAnswerTranscriptBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalBytes(for: MeshRoutedDrainAnswerFixtures.payload(), in: .fernlet),
                          by: Self.signatures.meshRoutedDrainAnswerV1,
                          consumer: "canonicalBytes(for: MeshRoutedDrainAnswerPayload, in:)")
    }

    /// The verify QR's fixed-width transcript opens with `proximityQRIdentityV1`, raw.
    @Test func theVerifyQRTranscriptBeginsWithItsFieldsPrefix() {
        let transcript = ProximityVerifyQR.canonicalBytes(
            version: 1, signingPublicKey: Data(repeating: 0x11, count: 32),
            keyAgreementPublicKey: Data(repeating: 0x22, count: 32), timestamp: 1_700_000_000,
            nonce: Data(repeating: 0x33, count: 16), in: .fernlet)
        Self.expectFramed(transcript, by: Self.signatures.proximityQRIdentityV1, consumer: "ProximityVerifyQR.canonicalBytes(...in:)")
    }

    /// The verify response's fixed-width transcript opens with `proximityQRResponseV1`, raw.
    @Test func theVerifyResponseTranscriptBeginsWithItsFieldsPrefix() {
        let transcript = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: Data(repeating: 0x44, count: 32),
            challengeNonce: Data(repeating: 0x55, count: 16), qrNonce: Data(repeating: 0x66, count: 16), in: .fernlet)
        Self.expectFramed(transcript, by: Self.signatures.proximityQRResponseV1,
                          consumer: "ProximityVerifySignature.message(...in:)")
    }

    /// The membership inventory digest's hash preimage opens with `lp(hash.meshInventoryDigestV1)`.
    @Test func theMembershipInventoryDigestPreimageBeginsWithItsFieldsPrefix() {
        Self.expectFramed(canonicalInventoryDigestBytes(for: [], in: .fernlet), by: Self.hashes.meshInventoryDigestV1,
                          consumer: "canonicalInventoryDigestBytes(for:in:)")
    }

    /// A routed item's content hash is SHA-256 over `lp(meshRoutedContentV1) ‖ blob`.
    @Test func theRoutedContentHashIsTakenOverItsFieldsPrefix() {
        let blob = Data("golden routed blob".utf8)
        Self.expectDigest(MeshRoutedContentDigest.contentHash(of: blob, in: .fernlet), over: blob,
                          by: Self.hashes.meshRoutedContentV1, consumer: "MeshRoutedContentDigest.contentHash(of:in:)")
    }

    /// The streaming content hasher is seeded with the same `lp(meshRoutedContentV1)`.
    @Test func theStreamedRoutedContentHashIsTakenOverItsFieldsPrefix() {
        var hasher = MeshRoutedContentHasher(purposes: .fernlet)
        hasher.update(Data("golden ".utf8))
        hasher.update(Data("routed blob".utf8))
        Self.expectDigest(hasher.finalized(), over: Data("golden routed blob".utf8), by: Self.hashes.meshRoutedContentV1,
                          consumer: "MeshRoutedContentHasher(purposes:)")
    }

    /// A chunk's payload hash is SHA-256 over `lp(hash.meshRoutedChunkV1) ‖ payload`.
    @Test func theRoutedChunkHashIsTakenOverItsFieldsPrefix() {
        let payload = Data("golden chunk payload".utf8)
        Self.expectDigest(MeshRoutedContentDigest.chunkHash(of: payload, in: .fernlet), over: payload,
                          by: Self.hashes.meshRoutedChunkV1, consumer: "MeshRoutedContentDigest.chunkHash(of:in:)")
    }

    /// A chunk's id is cut from SHA-256 over `lp(meshRoutedChunkIDV1) ‖ item ‖ index`.
    @Test func theRoutedChunkIDIsTakenOverItsFieldsPrefix() {
        let itemID = MeshChunkFixtures.itemID
        var tail = CanonicalByteWriter()
        tail.appendUUID(itemID)
        tail.appendUInt64(3)
        Self.expectDigest(Self.uuidBytes(MeshRoutedContentDigest.chunkID(itemID: itemID, chunkIndex: 3, in: .fernlet)),
                          over: tail.bytes, by: Self.hashes.meshRoutedChunkIDV1,
                          consumer: "MeshRoutedContentDigest.chunkID(itemID:chunkIndex:in:)")
    }

    /// A custody receipt's id is cut from SHA-256 over `lp(meshCustodyReceiptIDV1) ‖ item ‖ origin ‖ custodian`.
    @Test func theCustodyReceiptIDIsTakenOverItsFieldsPrefix() {
        let receipt = MeshCustodyReceiptFixtures.receipt()
        var tail = CanonicalByteWriter()
        tail.appendUUID(receipt.itemID)
        tail.appendString(receipt.originFingerprint)
        tail.appendString(receipt.custodianFingerprint)
        Self.expectDigest(Self.uuidBytes(receipt.receiptID(in: .fernlet)), over: tail.bytes,
                          by: Self.hashes.meshCustodyReceiptIDV1, consumer: "MeshCustodyReceipt.receiptID(in:)")
    }

    /// A recipient receipt's id is cut from SHA-256 over `lp(meshRecipientReceiptIDV1) ‖ item ‖ origin ‖ recipient`.
    @Test func theRecipientReceiptIDIsTakenOverItsFieldsPrefix() {
        let receipt = MeshRecipientReceiptFixtures.receipt()
        var tail = CanonicalByteWriter()
        tail.appendUUID(receipt.itemID)
        tail.appendString(receipt.originFingerprint)
        tail.appendString(receipt.recipientFingerprint)
        Self.expectDigest(Self.uuidBytes(receipt.receiptID(in: .fernlet)), over: tail.bytes,
                          by: Self.hashes.meshRecipientReceiptIDV1, consumer: "MeshRecipientReceipt.receiptID(in:)")
    }

    /// The epoch id is the one RAW hash prefix: the domain's bytes with no count, then the lowercase
    /// mesh id, the big-endian counter and the coordinator's fingerprint.
    @Test func theEpochIDIsTakenOverItsFieldsRawPrefix() throws {
        let meshID = MeshMembershipEventFixtures.meshID
        let epoch = try #require(MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000aa", meshID: meshID,
                                                     in: .fernlet))
        #expect(Self.hashes.meshEpochIDV1.prefixBytes == Self.hashes.meshEpochIDV1.data, "the epoch domain is a raw prefix")
        Self.expectDigest(Self.uuidBytes(epoch.epochID), over: Self.epochTail(meshID: meshID, counter: 7, coordinator: "00000000000000aa"),
                          by: Self.hashes.meshEpochIDV1, consumer: "MeshEpochRef.minted(counter:coordinatorFingerprint:meshID:in:)")
    }

    /// The routed item seal's authenticated data opens with `aead.meshRoutedItemV1`, raw (a consumer
    /// step A0.2.6 moved).
    @Test func theRoutedItemSealAuthenticatedDataBeginsWithItsFieldsPrefix() {
        Self.expectFramed(MeshRoutedItemSealer.additionalData(binding: MeshRoutedManifestFixtures.binding,
                                                              typeToken: MeshRoutedManifestFixtures.typeToken, in: .fernlet),
                          by: Self.aeads.meshRoutedItemV1, consumer: "MeshRoutedItemSealer.additionalData(binding:typeToken:in:)")
    }

    /// The routed content-key wrap's authenticated data opens with `aead.meshRoutedContentKeyWrapV1`,
    /// raw (a consumer step A0.2.6 moved).
    @Test func theRoutedKeyWrapAuthenticatedDataBeginsWithItsFieldsPrefix() {
        Self.expectFramed(MeshRoutedContentKeyWrapper.additionalData(binding: MeshRoutedManifestFixtures.binding,
                                                                     recipientFingerprint: "fp002", in: .fernlet),
                          by: Self.aeads.meshRoutedContentKeyWrapV1,
                          consumer: "MeshRoutedContentKeyWrapper.additionalData(binding:recipientFingerprint:in:)")
    }

    /// An identity envelope with every field set: the shape `CryptographicPurposeBoundaryTests`' framing
    /// cell signs.
    private static func consumerEnvelope() -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion, envelopeID: MeshMembershipEventFixtures.proposalID,
            senderSigningPublicKey: Data(repeating: 0x01, count: 32), senderKeyAgreementPublicKey: Data(repeating: 0x02, count: 32),
            senderDisplayName: "Golden", recipientFingerprint: nil, payloadType: .inspectorEcho, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Golden"), payload: Data("golden".utf8),
            createdAt: MeshMembershipEventFixtures.base, expiresAt: nil, signature: Data())
    }

    /// Expects the bytes a production consumer writes today to begin with `purpose.prefixBytes` and
    /// to carry more than it, and a signature role to accept them whole.
    private static func expectFramed(
        _ bytes: Data, by purpose: ProximityCryptographicPurpose, consumer: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let prefix = purpose.prefixBytes
        #expect(!prefix.isEmpty, "\(purpose.rawValue) puts no bytes in front of \(consumer)", sourceLocation: sourceLocation)
        #expect(bytes.count > prefix.count, "\(consumer) wrote \(bytes.count) bytes, no more than its prefix",
                sourceLocation: sourceLocation)
        #expect(bytes.starts(with: prefix), """
            \(consumer) begins \(hex(bytes.prefix(prefix.count))), but its field \(purpose.rawValue) has the role \
            \(purpose.role), which puts \(hex(prefix)) there: the role and its consumer have drifted apart
            """, sourceLocation: sourceLocation)
        guard case .signature = purpose.role else { return }
        #expect(purpose.signingBytes(bytes) == bytes, "\(purpose.rawValue) refuses the transcript \(consumer) writes",
                sourceLocation: sourceLocation)
    }

    /// Expects `actual`, a production digest or the 16-byte id cut from one, to be SHA-256 over
    /// `purpose.prefixBytes` followed by `tail`.
    private static func expectDigest(
        _ actual: Data, over tail: Data, by purpose: ProximityCryptographicPurpose, consumer: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected = Data(SHA256.hash(data: purpose.prefixBytes + tail))
        #expect(actual.count == 32 || actual.count == 16, "\(consumer) produced \(actual.count) bytes",
                sourceLocation: sourceLocation)
        #expect(actual == expected.prefix(actual.count), """
            \(consumer) is \(hex(actual)), not SHA-256 over its field's prefix (\(purpose.role), \
            \(hex(purpose.prefixBytes))) then its tail (\(hex(expected.prefix(actual.count)))): the hash \
            domain is consumed in another framing than its role says
            """, sourceLocation: sourceLocation)
    }

    // MARK: Group 7 — a foreign namespace (A0.2.2)

    /// `.fernlet` and a namespace built from another app's literals overlap nowhere: no label equal or
    /// byte-prefix related, no service type, ALPN, heartbeat or scheme shared, and no keychain
    /// service, directory or log subsystem either. Asked from both sides.
    @Test func aForeignNamespaceCollidesWithFernletNowhere() {
        let foreign = ForeignAppNamespace.namespace()
        #expect(foreign.soundness == .sound, "the foreign fixture is unsound: \(foreign.soundness)")
        let fernlet = ProximityNamespace.fernlet
        #expect(fernlet.familyCollisions(with: foreign).isEmpty, "\(fernlet.familyCollisions(with: foreign))")
        #expect(foreign.familyCollisions(with: fernlet).isEmpty, "\(foreign.familyCollisions(with: fernlet))")
        #expect(fernlet.installationCollisions(with: foreign).isEmpty, "\(fernlet.installationCollisions(with: foreign))")
        #expect(foreign.installationCollisions(with: fernlet).isEmpty, "\(foreign.installationCollisions(with: fernlet))")
    }

    /// No signature purpose of either namespace accepts a transcript framed for the other's, in either
    /// direction. The one exception is by construction and pinned rather than skipped: Fernlet's two
    /// legacy labels are `.signature(.absent)`, verify-only formats that carry no label, so they accept
    /// every transcript, the foreign app's included. The foreign app has no legacy peers (`.refused`).
    @Test func noSignaturePurposeOfEitherAcceptsATranscriptFramedForTheOther() {
        let body = Data("golden transcript body".utf8)
        let fernlet = ProximityNamespace.fernlet.labelRows.filter { Self.isSignatureRole($0.purpose.role) }
        let foreign = ForeignAppNamespace.namespace().labelRows.filter { Self.isSignatureRole($0.purpose.role) }
        #expect(fernlet.count == 21 && foreign.count == 19, "\(fernlet.count) Fernlet and \(foreign.count) foreign signature labels")
        var fernletAcceptors: Set<String> = []
        // R2: bounded by the 21 × 19 signature pairs.
        for mine in fernlet {
            for theirs in foreign {
                if mine.purpose.signingBytes(theirs.purpose.prefixBytes + body) != nil {
                    fernletAcceptors.insert(mine.field)
                }
                #expect(theirs.purpose.signingBytes(mine.purpose.prefixBytes + body) == nil,
                        "the foreign \(theirs.field) accepts a transcript framed for Fernlet's \(mine.field)")
            }
        }
        let legacy: Set<String> = ["family.purposes.signature.legacyV1.identityEnvelopeV1",
                                   "family.purposes.signature.legacyV1.meshAdmissionTokenV1"]
        #expect(fernletAcceptors == legacy, "Fernlet purposes that accept a foreign transcript: \(fernletAcceptors.sorted())")
    }

    /// The foreign namespace's vocabulary and presentation strings are its own: none of its tokens,
    /// titles, instance-name prefixes or its common name is one of `.fernlet`'s, so a cell that runs a
    /// consumer under it reads the namespace's value, never a Fernlet constant that happens to match.
    @Test func aForeignVocabularySharesNoStringWithFernlets() {
        let foreign = Self.vocabularyStrings(of: ForeignAppNamespace.namespace().family)
        let fernlet = Self.vocabularyStrings(of: ProximityNamespace.fernlet.family)
        #expect(foreign.count >= 20 && fernlet.count >= 70,
                "read only \(foreign.count) foreign and \(fernlet.count) Fernlet vocabulary strings")
        let shared = foreign.intersection(fernlet)
        #expect(shared.isEmpty, "the foreign fixture shares \(shared.sorted()) with .fernlet")
    }

    /// Every token, title and presentation string a family's vocabulary and radios carry.
    private static func vocabularyStrings(of family: ProximityNamespace.Family) -> Set<String> {
        let vocabulary = family.vocabulary
        let session = vocabulary.session
        let kinds = vocabulary.membershipRecordKinds
        let routed = vocabulary.routedTypes
        var strings: Set<String> = [
            session.identityIntroduction.payloadType, session.identityIntroduction.summaryTitle,
            session.identityAcknowledge.payloadType, session.identityAcknowledge.summaryTitle,
            session.heartbeat.payloadType, session.heartbeat.pingTitle, session.heartbeat.replyTitle,
            vocabulary.capabilities.wire2, kinds.admission, kinds.departure, kinds.removal, kinds.termination,
            routed.photo, routed.tempMessage, routed.heart, routed.control,
            family.radios.meshInstanceNamePrefix, family.radios.presenceInstanceNamePrefix, family.radios.tlsCommonName
        ]
        strings.formUnion(vocabulary.payloads.known)
        strings.formUnion(vocabulary.payloads.sealingRequired)
        strings.formUnion(vocabulary.capabilities.known)
        strings.formUnion(vocabulary.capabilities.assumedForLegacyPeers)
        strings.formUnion(vocabulary.mesh.fields.map(\.value))
        return strings
    }

    // MARK: Group 8 — the supply path (A0.2.3)

    /// The one label read A0.2.3 moves: an identity built from `.fernlet` with no service of its own
    /// keeps its rows under the frozen identity service, one built from another app's namespace keeps
    /// them under that app's (so the read is the namespace's field, not a literal that happens to
    /// match Fernlet's), and an explicit service still wins. The identity keeps the namespace it was
    /// handed, and its `purposes` are that namespace's. Construction touches no keychain row.
    @Test func theIdentityKeychainServiceIsReadOffTheNamespace() {
        let fernlet = IdentityService(namespace: .fernlet)
        #expect(fernlet.keychainService == Self.frozen("installation.keychain.identity.service"),
                "IdentityService(namespace: .fernlet) keeps its rows under \(fernlet.keychainService)")
        #expect(fernlet.namespace == ProximityNamespace.fernlet)
        #expect(fernlet.purposes == ProximityNamespace.fernlet.family.purposes)

        let foreignNamespace = ForeignAppNamespace.namespace()
        let foreign = IdentityService(namespace: foreignNamespace)
        #expect(foreign.keychainService == "org.example.acme.identity",
                "an identity under another app's namespace keeps its rows under \(foreign.keychainService)")
        #expect(foreign.purposes == foreignNamespace.family.purposes)

        let service = Self.isolatedIdentityService()
        let isolated = IdentityService(namespace: .fernlet, keychainService: service)
        #expect(isolated.keychainService == service, "an explicit keychain service no longer wins over the namespace's")
        #expect(isolated.namespace == ProximityNamespace.fernlet)
    }

    /// `sign` under a namespace label signs only the 19 writable signature labels, each over a
    /// transcript framed for it, and the signature verifies under the label and under its
    /// FernletCrypto twin alike. It refuses, with `invalidKeyData` — the error a misframed transcript
    /// has always thrown — a transcript framed for no label, the two verify-only legacy labels (they
    /// accept every transcript, so signing under one would make the identity an unscoped signing
    /// oracle) and all 20 labels in a non-signature role, the two feature salts among them.
    @Test func theNamespaceSignRefusesVerifyOnlyAndNonSignatureLabels() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        let twins = Dictionary(Self.registryTwins.map { ($0.field, $0.twin) }, uniquingKeysWith: { first, _ in first })
        let body = Data("golden transcript body".utf8)
        var signed = 0
        var refused: [ProximityCryptographicPurpose.Role: Int] = [:]
        // R2: bounded by the 41 label rows.
        for row in ProximityNamespace.fernlet.labelRows {
            let transcript = row.purpose.prefixBytes + body
            guard Self.isWritableSignatureRole(row.purpose.role) else {
                #expect(throws: IdentityError.invalidKeyData, "\(row.field) (\(row.purpose.role)) signed a transcript") {
                    _ = try identity.sign(transcript, purpose: row.purpose)
                }
                refused[row.purpose.role, default: 0] += 1
                continue
            }
            signed += 1
            let signature = try identity.sign(transcript, purpose: row.purpose)
            let key = identity.localSigningPublicKey
            #expect(IdentityService.verify(signature, of: transcript, by: key, purpose: row.purpose),
                    "\(row.field) does not verify the signature it made")
            let twin = try #require(twins[row.field], "\(row.field) has no FernletCrypto twin")
            #expect(IdentityService.verify(signature, of: transcript, by: key, purpose: twin),
                    "\(row.field)'s signature does not verify under its FernletCrypto twin")
            #expect(throws: IdentityError.invalidKeyData, "\(row.field) signed a transcript framed for no label") {
                _ = try identity.sign(body, purpose: row.purpose)
            }
        }
        #expect(signed == 19, "\(signed) labels signed; the design has 17 canonical and 2 QR transcripts")
        let expectedRefusals: [ProximityCryptographicPurpose.Role: Int] = [
            .signature(.absent): 2, .keyDerivationSalt: 5, .tlsExporterLabel: 1, .columnSeal: 2,
            .aeadAssociatedData: 5, .hashDomain(.lengthPrefixed): 6, .hashDomain(.rawPrefix): 1
        ]
        #expect(refused == expectedRefusals, "sign refused \(refused); the design refuses \(expectedRefusals)")
    }

    /// `verify` under a namespace label answers as the `CryptographicPurpose` overload answers under
    /// the label's FernletCrypto twin, for a genuine signature over `lp(label) ‖ body`, `label ‖ body`
    /// and `body`: each writable label accepts only its own framing and each legacy label all three.
    /// A label in a non-signature role verifies nothing at all — where its registry twin, which has
    /// no role, still accepts the raw-framed transcript.
    @Test func theNamespaceVerifyAcceptsWhatItsFernletCryptoTwinAccepts() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let publicKey = key.publicKey.rawRepresentation
        let twins = Dictionary(Self.registryTwins.map { ($0.field, $0.twin) }, uniquingKeysWith: { first, _ in first })
        let body = Data("golden transcript body".utf8)
        var compared = 0
        var refusing = 0
        // R2: bounded by the 41 label rows, three inputs each.
        for row in ProximityNamespace.fernlet.labelRows {
            let inputs = [Self.lengthPrefixed(row.purpose.data) + body, row.purpose.data + body, body]
            let signatures = try inputs.map { try key.signature(for: $0) }
            let accepted = zip(inputs, signatures).map {
                IdentityService.verify($1, of: $0, by: publicKey, purpose: row.purpose)
            }
            guard Self.isSignatureRole(row.purpose.role) else {
                refusing += 1
                #expect(accepted == [false, false, false], "\(row.field) (\(row.purpose.role)) verified \(accepted)")
                continue
            }
            compared += 1
            let twin = try #require(twins[row.field], "\(row.field) has no FernletCrypto twin")
            let twinAccepted = zip(inputs, signatures).map {
                IdentityService.verify($1, of: $0, by: publicKey, purpose: twin)
            }
            #expect(accepted == twinAccepted,
                    "\(row.field) verifies \(accepted) of [lp+body, label+body, body]; its twin \(twinAccepted)")
        }
        #expect(compared == 21 && refusing == 20, "\(compared) signature labels compared and \(refusing) refusing")
    }

    // MARK: Group 9 — the signed transcripts read the namespace they are handed (A0.2.4)

    /// The labels every test binding passes for a `ProximityNamespace.Purposes` (`.fernlet`) are the
    /// ones the app hands ProximityKit: FernletConnections' `ProximityNamespace.Purposes.fernlet` is
    /// `ProximityNamespace.fernlet`'s family purposes, so a suite that leans on a binding signs and
    /// verifies under Fernlet's bytes. So is the family the membership bindings pass for a
    /// `ProximityNamespace.Family`, labels and record kinds alike.
    @Test func theBindingsPassFernletsOwnPurposes() {
        #expect(ProximityNamespace.Purposes.fernlet == ProximityNamespace.fernlet.family.purposes,
                "the purposes the bindings pass are not the ones the app hands ProximityKit")
        #expect(ProximityNamespace.Family.fernlet == ProximityNamespace.fernlet.family,
                "the family the membership bindings pass is not the one the app hands ProximityKit")
    }

    /// The membership inventory digest's records hash is SHA-256 over `lp(hash.meshInventoryDigestV1)`
    /// then the counted record identities: `MeshInventoryDigest(meshID:ledger:family:)` consumes the
    /// field in the role it fixes, over a one-admission ledger whose tail is written here.
    @Test func theMembershipInventoryDigestHashIsTakenOverItsFieldsPrefix() {
        let ledger = MeshMembershipEventFixtures.singleAdmissionLedger()
        let identities = MeshInventoryDigest.identities(
            in: ledger, recordKinds: ProximityNamespace.fernlet.family.vocabulary.membershipRecordKinds)
        #expect(identities.count == 1)
        var tail = CanonicalByteWriter()
        tail.appendUInt64(UInt64(identities.count))
        // R2: bounded by the one admission.
        for identity in identities {
            tail.appendString(identity.kindToken)
            tail.appendString(identity.memberFingerprint)
            tail.appendDate(identity.occurredAt)
            tail.appendString(identity.authorFingerprint)
            tail.appendLengthPrefixed(identity.signature)
        }
        let digest = MeshInventoryDigest(meshID: MeshMembershipEventFixtures.meshID, ledger: ledger, family: .fernlet)
        Self.expectDigest(digest.recordsHash, over: tail.bytes, by: Self.hashes.meshInventoryDigestV1,
                          consumer: "MeshInventoryDigest(meshID:ledger:family:)")
    }

    /// A schema-v1 envelope — signed over the pre-WI-6 JSON bytes, which carry no label — still
    /// verifies under an identity of `.fernlet`, whose family accepts its legacy peers
    /// (`legacyV1.identityEnvelopeV1`), and is refused `signatureInvalid` under one of a family that
    /// refuses them (`.refused`: no label at all). No identity is provisioned: an unsealed broadcast
    /// envelope reads no key.
    @Test func aLegacyEnvelopeVerifiesOnlyWhereTheFamilyAcceptsLegacyPeers() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let sender = key.publicKey.rawRepresentation
        let unsigned = Self.legacyEnvelope(sender: sender, signature: Data())
        let envelope = Self.legacyEnvelope(sender: sender, signature: try key.signature(for: legacyCanonicalBytes(for: unsigned)))
        let fernlet = IdentityService(namespace: .fernlet, keychainService: Self.isolatedIdentityService())
        #expect(try envelope.verify(identityService: fernlet, replayCache: nil) == envelope.payload,
                "a schema-v1 envelope no longer verifies under .fernlet")
        let foreign = IdentityService(namespace: ForeignAppNamespace.namespace(),
                                      keychainService: Self.isolatedIdentityService())
        #expect(throws: FernletIdentityEnvelope.VerifyError.signatureInvalid,
                "a family that refuses legacy peers verified a schema-v1 envelope") {
            _ = try envelope.verify(identityService: foreign, replayCache: nil)
        }
    }

    /// An envelope minted by `signed(identityService:...)` under one namespace verifies under an
    /// identity of that namespace and is refused `signatureInvalid` under the other, in both
    /// directions: the builder and the verifier each read their identity's `purposes`, never a fixed
    /// label. Each carries its signer's heartbeat token, one its own namespace dispatches unsealed, so
    /// the verify that succeeds opens the payload rather than parking it.
    @Test func anEnvelopeVerifiesUnderTheNamespaceItWasSignedIn() throws {
        let fernletService = Self.isolatedIdentityService()
        let foreignService = Self.isolatedIdentityService()
        defer {
            KeychainItem.deleteAll(service: fernletService)
            KeychainItem.deleteAll(service: foreignService)
        }
        let fernlet = IdentityService(namespace: .fernlet, keychainService: fernletService)
        let foreign = IdentityService(namespace: ForeignAppNamespace.namespace(), keychainService: foreignService)
        try fernlet.ensureProvisioned()
        try foreign.ensureProvisioned()
        let payload = Data("golden".utf8)
        // R2: bounded by the two directions.
        for (signer, other) in [(fernlet, foreign), (foreign, fernlet)] {
            let envelope = try FernletIdentityEnvelope.signed(
                identityService: signer, senderDisplayName: "Golden",
                payloadTypeToken: signer.namespace.family.vocabulary.session.heartbeat.payloadType,
                payloadSummary: PayloadSummary(title: "Golden"), payload: payload)
            #expect(try envelope.verify(identityService: signer, replayCache: nil) == payload,
                    "an envelope signed under \(signer.purposes.signature.identityEnvelopeV2.rawValue) did not verify there")
            #expect(throws: FernletIdentityEnvelope.VerifyError.signatureInvalid,
                    "an envelope signed under \(signer.purposes.signature.identityEnvelopeV2.rawValue) verified elsewhere") {
                _ = try envelope.verify(identityService: other, replayCache: nil)
            }
        }
    }

    /// A pre-WI-6 admission token — the admitter's signature over the legacy JSON bytes, which carry no
    /// label — still verifies `in: .fernlet` through the dual verify's legacy alternative, and is
    /// refused `signatureInvalid` in a family that refuses legacy peers, which has no such alternative.
    @Test func aLegacyAdmissionTokenVerifiesOnlyWhereTheFamilyAcceptsLegacyPeers() throws {
        let admitter = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let joiner = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x80))
        let keys = (admitter: admitter.publicKey.rawRepresentation, joiner: joiner.publicKey.rawRepresentation)
        let unsigned = Self.admissionToken(admitter: keys.admitter, joiner: keys.joiner, signature: Data())
        let legacy = Self.admissionToken(admitter: keys.admitter, joiner: keys.joiner,
                                         signature: try admitter.signature(for: legacyCanonicalBytes(for: unsigned)))
        try Self.verifyToken(legacy, keys: keys, in: .fernlet)
        #expect(throws: MeshAdmissionToken.VerifyError.signatureInvalid,
                "a family that refuses legacy peers verified a pre-WI-6 token") {
            try Self.verifyToken(legacy, keys: keys, in: ForeignAppNamespace.namespace().family.purposes)
        }
    }

    /// A canonical admission token signed under one namespace's label verifies in that namespace and is
    /// refused `signatureInvalid` in the other, in both directions — `.fernlet`'s legacy alternative
    /// included, since its verify-only label accepts only the legacy bytes' signature.
    @Test func anAdmissionTokenVerifiesUnderTheNamespaceItWasSignedIn() throws {
        let admitter = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let joiner = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x80))
        let keys = (admitter: admitter.publicKey.rawRepresentation, joiner: joiner.publicKey.rawRepresentation)
        let unsigned = Self.admissionToken(admitter: keys.admitter, joiner: keys.joiner, signature: Data())
        let foreign = ForeignAppNamespace.namespace().family.purposes
        // R2: bounded by the two directions.
        for (signer, other) in [(ProximityNamespace.Purposes.fernlet, foreign), (foreign, .fernlet)] {
            let token = Self.admissionToken(admitter: keys.admitter, joiner: keys.joiner,
                                            signature: try admitter.signature(for: canonicalBytes(for: unsigned, in: signer)))
            try Self.verifyToken(token, keys: keys, in: signer)
            #expect(throws: MeshAdmissionToken.VerifyError.signatureInvalid,
                    "a token signed under \(signer.signature.meshAdmissionTokenV2.rawValue) verified elsewhere") {
                try Self.verifyToken(token, keys: keys, in: other)
            }
        }
    }

    /// A membership verifier checks every signature under its own copy of the labels. An admission and
    /// a departure signed by an identity of the foreign namespace are accepted by a verifier holding
    /// that namespace's family and refused `signatureInvalid` by one holding `.fernlet`'s, over the
    /// very same ledger; so is the signed inventory digest, whose records hash only the verifier of
    /// the signer's namespace finds equal to its own.
    @Test func aMembershipVerifierChecksUnderItsOwnCopyOfTheLabels() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let foreignNamespace = ForeignAppNamespace.namespace()
        let member = IdentityService(namespace: foreignNamespace, keychainService: service)
        try member.ensureProvisioned()
        let meshID = MeshMembershipEventFixtures.meshID
        let admission = try Self.selfAdmission(of: member, meshID: meshID)
        let founderKey = member.localSigningPublicKey
        var foreignView = MeshMembershipRecordVerifier(meshID: meshID, founderSigningPublicKey: founderKey,
                                                       family: foreignNamespace.family)
        var fernletView = MeshMembershipRecordVerifier(meshID: meshID, founderSigningPublicKey: founderKey,
                                                       family: .fernlet)
        #expect(fernletView.insert(admission) == .signatureInvalid, "a foreign admission verified under .fernlet")
        #expect(foreignView.insert(admission) == nil, "a verifier refused an admission signed in its own namespace")

        var fernletOverTheSameLedger = MeshMembershipRecordVerifier(
            meshID: meshID, founderSigningPublicKey: founderKey, ledger: foreignView.ledger, family: .fernlet)
        let digest = try MeshInventoryDigestPayload.signed(meshID: meshID, ledger: foreignView.ledger, identity: member)
        #expect(foreignView.verify(digest) == nil && foreignView.matchesLocalInventory(digest.digest),
                "the signer's namespace refused its own digest, or hashed its ledger otherwise")
        #expect(fernletOverTheSameLedger.verify(digest) == .signatureInvalid, "a foreign digest verified under .fernlet")
        #expect(!fernletOverTheSameLedger.matchesLocalInventory(digest.digest),
                "two namespaces hashed one ledger to the same digest")
        let departure = try SignedDepartureRecord.signed(meshID: meshID, identity: member,
                                                          occurredAt: MeshMembershipEventFixtures.base)
        #expect(fernletOverTheSameLedger.insert(departure) == .signatureInvalid, "a foreign departure verified under .fernlet")
        #expect(foreignView.insert(departure) == nil, "a verifier refused a departure signed in its own namespace")
    }

    /// The joiner's two ledger steps re-verify under the labels they are handed: a self-admission
    /// signed in the foreign namespace bootstraps a verifier there and is refused in `.fernlet`
    /// (`ownAdmissionRefused(signatureInvalid)`), and a ledger rooted in it is adopted there and
    /// refused in `.fernlet`, whose re-verification admits nobody from it (`admitterNotChained`).
    @Test func theLedgerAdoptionVerifiesUnderTheLabelsItIsHanded() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let foreignNamespace = ForeignAppNamespace.namespace()
        let foreign = foreignNamespace.family
        let founder = IdentityService(namespace: foreignNamespace, keychainService: service)
        try founder.ensureProvisioned()
        let meshID = MeshMembershipEventFixtures.meshID
        let own = try Self.selfAdmission(of: founder, meshID: meshID)

        let bootstrap = MeshLedgerAdoption.bootstrapVerifier(meshID: meshID, ownAdmission: own, in: foreign)
        guard case .adopted(let rooted) = bootstrap else {
            Issue.record("the foreign namespace refused its own admission at bootstrap: \(String(describing: Self.refusal(bootstrap)))")
            return
        }
        #expect(Self.refusal(MeshLedgerAdoption.bootstrapVerifier(meshID: meshID, ownAdmission: own, in: .fernlet))
                    == .ownAdmissionRefused(.signatureInvalid), "a foreign admission bootstrapped under .fernlet")
        let offered = rooted.ledger
        #expect(Self.refusal(MeshLedgerAdoption.adopt(offered: offered, ownAdmission: own, meshID: meshID, in: foreign)) == nil,
                "the foreign namespace refused to adopt a ledger rooted in its own admission")
        #expect(Self.refusal(MeshLedgerAdoption.adopt(offered: offered, ownAdmission: own, meshID: meshID, in: .fernlet))
                    == .admitterNotChained, "a foreign ledger was adopted under .fernlet")
    }

    // MARK: Group 10 — the routed transcripts, the introduction and the QR read the namespace (A0.2.5)

    /// The verify QR's scheme and its identity transcript's label are its namespace's: a code made by
    /// an identity of `.fernlet` carries the frozen scheme and one made by an identity of another app
    /// carries that app's, and each parses (`parse(_:in:)`) and validates (`isValid(_:at:in:)`) only
    /// in the namespace it was made in, both ways.
    @Test func theVerifyQRReadsItsSchemeAndLabelOffTheNamespace() throws {
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let foreignNamespace = ForeignAppNamespace.namespace()
        let fernlet = IdentityService(namespace: .fernlet, keychainService: services[0])
        let foreign = IdentityService(namespace: foreignNamespace, keychainService: services[1])
        try fernlet.ensureProvisioned()
        try foreign.ensureProvisioned()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fernletURL = try ProximityVerifyQR.makeURL(identity: fernlet, now: now).url
        let foreignURL = try ProximityVerifyQR.makeURL(identity: foreign, now: now).url
        #expect(fernletURL.scheme == Self.frozen("family.verifyQR.urlScheme"),
                "a code made under .fernlet carries the scheme \(fernletURL.scheme ?? "none")")
        #expect(foreignURL.scheme == foreignNamespace.family.verifyQR.urlScheme,
                "a code made under another app's namespace carries the scheme \(foreignURL.scheme ?? "none")")
        let directions = [(fernletURL, ProximityNamespace.fernlet, foreignNamespace),
                          (foreignURL, foreignNamespace, ProximityNamespace.fernlet)]
        // R2: bounded by the two directions.
        for (url, own, other) in directions {
            let label = own.family.purposes.signature.proximityQRIdentityV1.rawValue
            let payload = try #require(ProximityVerifyQR.parse(url, in: own), "\(url) did not parse in its own namespace")
            #expect(ProximityVerifyQR.parse(url, in: other) == nil, "\(url) parsed in another namespace")
            #expect(ProximityVerifyQR.isValid(payload, at: now, in: own.family.purposes),
                    "a code signed under \(label) was invalid there")
            #expect(!ProximityVerifyQR.isValid(payload, at: now, in: other.family.purposes),
                    "a code signed under \(label) validated under another namespace's label")
        }
    }

    /// The verify response's transcript is framed by the namespace it is built in (`message(...in:)`),
    /// so a response signed over one namespace's transcript verifies under that namespace's label and
    /// under no other's, both ways: the check the manager's, the coach's and the duress flow's
    /// ceremonies all make.
    @Test func aVerifyResponseVerifiesOnlyUnderTheNamespaceItWasBuiltIn() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let publicKey = key.publicKey.rawRepresentation
        let foreign = ForeignAppNamespace.namespace().family.purposes
        // R2: bounded by the two directions.
        for (signer, other) in [(ProximityNamespace.Purposes.fernlet, foreign), (foreign, ProximityNamespace.Purposes.fernlet)] {
            let message = Self.verifyResponse(in: signer)
            let label = signer.signature.proximityQRResponseV1
            Self.expectFramed(message, by: label, consumer: "ProximityVerifySignature.message(...in:)")
            let signature = try key.signature(for: message)
            #expect(IdentityService.verify(signature, of: message, by: publicKey, purpose: label),
                    "a response framed for \(label.rawValue) did not verify there")
            #expect(!IdentityService.verify(signature, of: message, by: publicKey, purpose: other.signature.proximityQRResponseV1),
                    "a response framed for \(label.rawValue) verified under another namespace's label")
            #expect(!IdentityService.verify(signature, of: Self.verifyResponse(in: other), by: publicKey,
                                            purpose: other.signature.proximityQRResponseV1),
                    "a response signed for \(label.rawValue) verified over another namespace's transcript")
        }
    }

    /// `CoachVerificationCeremony` — a reader of both QR transcripts that the design's commit list left
    /// out — runs its whole round under its identity's namespace: two coaches of another app display,
    /// scan, challenge, respond and prove under that app's scheme and labels, and a scanner of
    /// `.fernlet` refuses the other app's code before any challenge is minted.
    @Test func aCoachCeremonyRunsUnderItsIdentitysNamespace() throws {
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let foreignNamespace = ForeignAppNamespace.namespace()
        let displayer = IdentityService(namespace: foreignNamespace, keychainService: services[0])
        let scanner = IdentityService(namespace: foreignNamespace, keychainService: services[1])
        let fernletScanner = IdentityService(namespace: .fernlet, keychainService: services[2])
        // R2: bounded by the three identities.
        for identity in [displayer, scanner, fernletScanner] {
            try identity.ensureProvisioned()
        }
        let display = CoachVerificationCeremony(identity: displayer)
        let scan = CoachVerificationCeremony(identity: scanner)
        let url = try #require(display.makeDisplayURL(forPeerSigningKey: scanner.localSigningPublicKey))
        #expect(url.scheme == foreignNamespace.family.verifyQR.urlScheme, "the coach displayed \(url.scheme ?? "no scheme")")
        #expect(CoachVerificationCeremony(identity: fernletScanner).beginVerification(
            scannedURL: url, expectedPeerSigningKey: displayer.localSigningPublicKey) == nil,
                "a .fernlet scanner opened a round on another app's code")
        let challenge = try #require(scan.beginVerification(
            scannedURL: url, expectedPeerSigningKey: displayer.localSigningPublicKey), "the coach refused its own app's code")
        let verdict = display.handleChallenge(challenge, senderSigningPublicKey: scanner.localSigningPublicKey,
                                              senderKeyAgreementPublicKey: scanner.localKeyAgreementPublicKey)
        guard case .respond(let response) = verdict else {
            Issue.record("the displaying coach did not answer its own app's challenge: \(verdict)")
            return
        }
        #expect(scan.handleResponse(response, senderSigningPublicKey: displayer.localSigningPublicKey),
                "the scanning coach refused a response signed under its own app's label")
    }

    /// The six routed doors check every signature under their own copy of the labels. One key, admitted
    /// to the fixtures' mesh, signs a manifest, a chunk, both receipts, a routed inventory digest and a
    /// drain answer over the bytes one namespace frames for each: every door holding that namespace's
    /// purposes accepts its record, and every door holding the other's refuses it `signatureInvalid`,
    /// both ways.
    @Test func theRoutedVerifiersCheckUnderTheirOwnCopyOfTheLabels() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let foreign = ForeignAppNamespace.namespace().family.purposes
        let doors: Set<String> = ["manifest", "chunk", "custodyReceipt", "recipientReceipt", "routedInventory", "drainAnswer"]
        // R2: bounded by the two directions.
        for (signer, other) in [(ProximityNamespace.Purposes.fernlet, foreign), (foreign, ProximityNamespace.Purposes.fernlet)] {
            let label = signer.signature.meshRoutedManifestV1.rawValue
            let own = try Self.routedVerdicts(signedBy: key, in: signer, checkedIn: signer)
            let elsewhere = try Self.routedVerdicts(signedBy: key, in: signer, checkedIn: other)
            #expect(Set(own.keys) == doors && Set(elsewhere.keys) == doors, "\(own.keys.sorted()) \(elsewhere.keys.sorted())")
            #expect(own.values.allSatisfy { $0 == "accepted" }, "the doors of the signer's own namespace (\(label)) answered \(own)")
            #expect(elsewhere.values.allSatisfy { $0 == MeshChunkRejection.signatureInvalid.rawValue },
                    "the doors of another namespace answered \(elsewhere) for records signed under \(label)")
        }
    }

    /// The channel-introduction exchange frames its transcript and checks the peer's signature under
    /// its own copy of the labels. An initiator holding one namespace's purposes binds a transcript
    /// that opens with that namespace's `lp(meshChannelIntroductionV1)`; a responder holding the same
    /// purposes accepts the initiator's signature over it, and one holding the other namespace's
    /// refuses it `signatureInvalid`, both ways.
    @Test func theChannelIntroductionExchangeChecksUnderItsOwnCopyOfTheLabels() throws {
        let meshID = MeshMembershipEventFixtures.meshID
        let initiator = MeshIntroductionHarness.endpoint(meshID: meshID, sessionID: "golden-initiator")
        let responder = MeshIntroductionHarness.endpoint(meshID: meshID, sessionID: "golden-responder")
        let foreign = ForeignAppNamespace.namespace().family.purposes
        // R2: bounded by the two directions.
        for (signer, other) in [(ProximityNamespace.Purposes.fernlet, foreign), (foreign, ProximityNamespace.Purposes.fernlet)] {
            var dialer = MeshChannelIntroductionExchange(role: .initiator, localHello: initiator.hello, purposes: signer)
            var nonces = MeshIntroductionNonceCache()
            #expect(dialer.receive(responder.hello, roster: MeshIntroductionHarness.roster(initiator, responder),
                                   nonces: &nonces) == nil)
            let bound = dialer.bind(channelBindingHash: MeshIntroductionHarness.binding)
            let transcript = try #require(bound, "an initiator holding \(signer.signature.meshChannelIntroductionV1.rawValue) bound nothing")
            Self.expectFramed(transcript, by: signer.signature.meshChannelIntroductionV1,
                              consumer: "MeshChannelIntroductionExchange.bind(channelBindingHash:)")
            let signed = MeshChannelIntroduction(channelBindingHash: MeshIntroductionHarness.binding,
                                                 signature: try initiator.signingKey.signature(for: transcript))
            let label = signer.signature.meshChannelIntroductionV1.rawValue
            #expect(Self.review(signed, from: initiator, by: responder, in: signer).verifiedPeer != nil,
                    "a responder holding \(label) refused an introduction signed under it")
            #expect(Self.review(signed, from: initiator, by: responder, in: other) == .rejected(.signatureInvalid),
                    "a responder holding another namespace's labels accepted an introduction signed under \(label)")
        }
    }

    /// The manager hands its transport its own copy of the host's namespace and signs the
    /// introduction that transport frames under that namespace's label. Since step A0.2.7 the radio
    /// the manager builds keeps its own copy of the labels, read off the namespace it is built from
    /// (A0.2.5 read them off the authority, before the radio held a namespace): that radio's purposes
    /// are the store's, and a transcript framed with them is signed and verifies under the label; one
    /// framed for another app's label is refused at the signing boundary.
    @Test func theManagerSignsTheIntroductionUnderTheNamespaceItHandsItsTransport() throws {
        let store = makeTestStore()
        defer { withExtendedLifetime(store) {} }   // `MeshNetworkManager.store` is `unowned`
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let manager = MeshNetworkManager(store: store, transport: nil,
                                         identity: IdentityService(namespace: .fernlet, keychainService: service))
        let radio = try #require(manager.transportForTesting as? NetworkMeshSession, "the manager built no QUIC radio")
        #expect(radio.purposes == store.proximityNamespace.family.purposes
                    && radio.purposes == ProximityNamespace.fernlet.family.purposes,
                "the manager hands its transport another namespace's labels than the host's")
        let authority: any MeshIntroductionAuthority = manager
        let framed = canonicalBytes(for: Self.introductionTranscript(), in: radio.purposes)
        let signature = try authority.signChannelIntroduction(framed)
        #expect(IdentityService.verify(signature, of: framed, by: authority.localSigningPublicKey,
                                       purpose: Self.signatures.meshChannelIntroductionV1),
                "the authority's introduction does not verify under the label of the namespace it hands its transport")
        #expect(throws: IdentityError.invalidKeyData, "the manager signed a transcript framed for another app's label") {
            _ = try authority.signChannelIntroduction(
                canonicalBytes(for: Self.introductionTranscript(), in: ForeignAppNamespace.namespace().family.purposes))
        }
    }

    // MARK: Group 11 — the hashes, seals, salts and the epoch read the namespace (A0.2.6)

    /// Every routed digest and id is SHA-256 over the field prefix of the namespace it is handed: the
    /// one-shot and streamed content hashes, the chunk hash, the chunk id (the static and the chunk's
    /// own) and both receipt ids, each recomputed here from that namespace's field and the reader's
    /// tail, under `.fernlet` and under another app's namespace — and no reader derives the same
    /// bytes under both.
    @Test func theRoutedDigestsAndIDsAreTakenOverTheNamespaceTheyAreHanded() {
        let fernlet = Self.routedDigests(in: .fernlet)
        let foreign = Self.routedDigests(in: ForeignAppNamespace.namespace().family.purposes)
        #expect(fernlet.count == 7 && Set(fernlet.keys) == Set(foreign.keys), "\(fernlet.keys.sorted()) \(foreign.keys.sorted())")
        // R2: bounded by the seven readers.
        for (reader, value) in fernlet {
            #expect(foreign[reader] != value, "\(reader) derived the same bytes under two namespaces")
        }
    }

    /// The chunk doors re-derive a payload's hash under the labels they hold or are handed, and read
    /// nothing else of the namespace for it. Fernlet's labels and a variant whose hash group alone is
    /// another app's share every signature label, so one key's signature verifies under both: a chunk
    /// hashed in one is accepted by a verifier holding that one and refused `chunkHashMismatch` by a
    /// verifier holding the other, and the reassembler admits it, and completes its item, only under
    /// the labels it is handed — both ways.
    @Test func theChunkDoorsMeasureUnderTheLabelsTheyHoldOrAreHanded() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sequence(from: 0x40))
        let variant = Self.fernletPurposes(hash: ForeignAppNamespace.hash())
        // R2: bounded by the two directions.
        for (hashedIn, other) in [(ProximityNamespace.Purposes.fernlet, variant), (variant, ProximityNamespace.Purposes.fernlet)] {
            let label = hashedIn.hash.meshRoutedChunkV1.rawValue
            let chunk = try Self.signedChunk(by: key, hashedIn: hashedIn)
            #expect(Self.chunkVerdict(chunk, signedBy: key, heldIn: hashedIn) == nil,
                    "a verifier holding \(label) refused a chunk hashed under it")
            #expect(Self.chunkVerdict(chunk, signedBy: key, heldIn: other) == .chunkHashMismatch,
                    "a verifier holding another hash label accepted a chunk hashed under \(label)")
            var parked = try #require(MeshChunkAssembly.forChunk(chunk))
            var probe = parked
            #expect(probe.admit(chunk, in: other) == .refused(.chunkHashMismatch), "parked under another label: \(label)")
            #expect(parked.admit(chunk, in: hashedIn) == .admitted(received: 1, expected: Int(chunk.chunkCount)))
            let item = Self.singleChunkItem(hashedIn: hashedIn)
            var bound = try #require(MeshChunkAssembly.forManifest(item.manifest))
            #expect(bound.admit(item.chunk, in: hashedIn) == .admitted(received: 1, expected: 1))
            #expect(bound.completion(against: item.manifest, in: other) == .refused(.contentHashMismatch),
                    "an item hashed under \(hashedIn.hash.meshRoutedContentV1.rawValue) completed under another label")
            #expect(bound.completion(against: item.manifest, in: hashedIn) == .complete(blob: item.blob))
        }
    }

    /// The chunker and the routed store measure an item under the namespace they are handed. An
    /// origin of another app's namespace slices an item whose manifest hashes in that namespace and
    /// stamps the chunk with that namespace's chunk hash, while an origin of `.fernlet` refuses the
    /// same item `contentHashMismatch`; and the store stages that chunk, commits custody of the item
    /// and hands its blob back only when its scope carries that namespace's labels — refusing the
    /// chunk `chunkHashMismatch`, the commit `contentHashMismatch` and the blob otherwise. (Step
    /// A0.2.6 handed the store's three verbs the labels; since A0.2.8 the scope carries them.)
    @Test func theChunkerAndTheRoutedStoreMeasureUnderTheNamespaceTheyAreHanded() throws {
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let foreignNamespace = ForeignAppNamespace.namespace()
        let foreign = foreignNamespace.family.purposes
        let origin = IdentityService(namespace: foreignNamespace, keychainService: services[0])
        let fernletOrigin = IdentityService(namespace: .fernlet, keychainService: services[1])
        try origin.ensureProvisioned()
        try fernletOrigin.ensureProvisioned()
        let blob = MeshChunkFixtures.blob(byteCount: 1_000)
        let manifest = MeshRoutedManifestFixtures.manifest().replacing(
            originFingerprint: origin.localFingerprint,
            contentHash: MeshRoutedContentDigest.contentHash(of: blob, in: foreign), size: UInt64(blob.count))
        let chunks = try MeshChunker.chunks(of: blob, for: manifest, identity: origin)
        #expect(chunks.map(\.chunkHash) == [MeshRoutedContentDigest.chunkHash(of: blob, in: foreign)],
                "the chunker hashed the slice under another namespace than its origin's")
        #expect(throws: MeshChunkMintError.contentHashMismatch, "an origin of .fernlet measured a foreign item as its own") {
            _ = try MeshChunker.chunks(of: blob, for: manifest.replacing(originFingerprint: fernletOrigin.localFingerprint),
                                       identity: fernletOrigin)
        }
        let chunk = try #require(chunks.first)
        Self.expectStoreMeasures(chunk, of: blob, manifest: manifest, hashedIn: foreignNamespace.family,
                                 notIn: ProximityNamespace.fernlet.family)
    }

    /// The routed item seal and the content-key wrap open only under the labels they were sealed
    /// under, each read on its own. Over Fernlet's labels and two variants — one whose key-derivation
    /// group, one whose AEAD group is another app's — a blob opens only where the AEAD labels match
    /// (the seal reads no salt) and a wrap only where both the salt and the AEAD label do; every
    /// other pairing is `openFailed`, and each door's authenticated data opens with the prefix of the
    /// AEAD field it was sealed under.
    @Test func theRoutedSealsOpenOnlyUnderTheLabelsTheyWereSealedUnder() throws {
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.sequence(from: 0x30))
        let agreement: (Data) throws -> SharedSecret = {
            try recipient.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0))
        }
        let (binding, token) = (MeshRoutedManifestFixtures.binding, MeshRoutedManifestFixtures.typeToken)
        let (contentKey, plaintext) = (Self.sequence(from: 0x10), Data("golden routed item".utf8))
        let variants = Self.saltAndAEADVariants()
        // R2: bounded by the three × three variant pairs.
        for (sealedName, sealedIn) in variants {
            let blob = try MeshRoutedItemSealer.seal(plaintext, contentKey: contentKey, binding: binding, typeToken: token,
                                                     in: sealedIn)
            let wrap = try MeshRoutedContentKeyWrapper.wrap(
                contentKey: contentKey, recipientFingerprint: "fp002",
                recipientKeyAgreementPublicKey: recipient.publicKey.rawRepresentation, binding: binding, in: sealedIn)
            Self.expectFramed(MeshRoutedItemSealer.additionalData(binding: binding, typeToken: token, in: sealedIn),
                              by: sealedIn.aead.meshRoutedItemV1, consumer: "the item seal's AAD under \(sealedName)")
            Self.expectFramed(MeshRoutedContentKeyWrapper.additionalData(binding: binding, recipientFingerprint: "fp002",
                                                                         in: sealedIn),
                              by: sealedIn.aead.meshRoutedContentKeyWrapV1, consumer: "the key wrap's AAD under \(sealedName)")
            for (openedName, openedIn) in variants {
                let item = Result { try MeshRoutedItemSealer.open(blob, contentKey: contentKey, binding: binding,
                                                                  typeToken: token, in: openedIn) }
                let key = Result { try MeshRoutedContentKeyWrapper.unwrap(
                    wrap, binding: binding, localFingerprint: "fp002",
                    localKeyAgreementPublicKey: recipient.publicKey.rawRepresentation, staticAgreement: agreement,
                    in: openedIn) }
                #expect(Self.opened(item, expecting: plaintext, refusal: MeshRoutedItemSealError.openFailed)
                            == (sealedIn.aead == openedIn.aead),
                        "an item sealed under \(sealedName) answered \(item) under \(openedName)")
                #expect(Self.opened(key, expecting: contentKey, refusal: MeshRoutedKeyWrapError.openFailed) == (sealedIn == openedIn),
                        "a key wrapped under \(sealedName) answered \(key) under \(openedName)")
            }
        }
    }

    /// An identity's transport seal and group-key wrap open only for an identity holding the same
    /// labels, the salt and the AEAD label each on its own: identities of Fernlet's labels and of the
    /// two variants (another app's key-derivation group; another app's AEAD group) each seal a payload
    /// and wrap a group key to all three, and only the recipient of the sender's own labels opens
    /// either; every other recipient answers `openFailed`.
    @Test func anIdentitySealsAndWrapsOnlyForAnIdentityOfItsOwnLabels() throws {
        let variants = Self.saltAndAEADVariants()
        let services = variants.map { _ in Self.isolatedIdentityService() }
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        var identities: [(name: String, identity: IdentityService)] = []
        // R2: bounded by the three variants.
        for (index, variant) in variants.enumerated() {
            let identity = IdentityService(namespace: Self.fernletNamespace(with: variant.purposes), keychainService: services[index])
            try identity.ensureProvisioned()
            identities.append((variant.name, identity))
        }
        let (plaintext, groupKey) = (Data("golden transport".utf8), Self.sequence(from: 0xE0))
        // R2: bounded by the three × three sender–recipient pairs.
        for (senderName, sender) in identities {
            for (recipientName, recipient) in identities {
                let own = senderName == recipientName
                let sealed = try sender.seal(plaintext, to: recipient.localKeyAgreementPublicKey)
                let wrapped = try sender.encryptGroupKey(groupKey, for: recipient.localKeyAgreementPublicKey)
                let opened = Result { try recipient.open(sealed, from: sender.localKeyAgreementPublicKey) }
                let unwrapped = Result { try recipient.decryptGroupKey(wrapped) }
                #expect(Self.opened(opened, expecting: plaintext, refusal: IdentityError.openFailed) == own,
                        "a seal from \(senderName) answered \(opened) at \(recipientName)")
                #expect(Self.opened(unwrapped, expecting: groupKey, refusal: IdentityError.openFailed) == own,
                        "a group key wrapped by \(senderName) answered \(unwrapped) at \(recipientName)")
            }
        }
    }

    /// The manager's encrypted-metadata door authenticates under its host's namespace, not a fixed
    /// label. A manager whose host supplies another app's namespace joins a mesh through that app's
    /// admitter — its token checked and its group key unwrapped under that namespace — and is then
    /// handed two wrappers sealed under the joined group key: one under that app's metadata label,
    /// which opens and renames the mesh, and a control under Fernlet's, stamped later so it would win
    /// the name if it opened. It does not. Every frame travels under that app's mesh messages, which
    /// are what the manager dispatches by.
    @Test func theManagerOpensEncryptedMetadataUnderItsHostsNamespace() async throws {
        let foreign = ForeignAppNamespace.namespace()
        let host = ForeignNamespaceHost(namespace: foreign)
        defer { withExtendedLifetime(host) { host.tearDown() } }   // `MeshNetworkManager.store` is `unowned`
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession(),
                                         identity: IdentityService(namespace: foreign, keychainService: services[0]))
        #expect(manager.namespace == foreign, "the manager keeps another namespace than its host's")
        let coordinator = Self.unprovisionedCoordinator()
        manager.addSlotForTesting(coordinator: coordinator,
                                  peer: PeerHandle(id: UUID(), displayHint: "Member", discoveryInfo: nil,
                                                   advertisedFingerprint: nil),
                                  fingerprint: "fp-member")
        let admitter = IdentityService(namespace: foreign, keychainService: services[1])
        try admitter.ensureProvisioned()
        let groupKey = Self.sequence(from: 0x70)
        let mesh = try Self.join(manager, on: coordinator, admitter: admitter, groupKey: groupKey, epoch: 5)
        #expect(manager.currentGroupKey?.keyBytes == groupKey, "precondition: the join installed the group key")

        try Self.deliverMetadata(Self.renamed(mesh, to: "Refused", secondsLater: 2),
                                 label: Self.frozen("family.purposes.aead.meshEncryptedMetadataV2"), groupKey: groupKey,
                                 nonce: Self.sequence(from: 0x5C, count: 12), epoch: 5, to: manager, on: coordinator)
        try Self.deliverMetadata(Self.renamed(mesh, to: "Golden", secondsLater: 1),
                                 label: foreign.family.purposes.aead.meshEncryptedMetadataV2.rawValue, groupKey: groupKey,
                                 nonce: Self.sequence(from: 0x50, count: 12), epoch: 5, to: manager, on: coordinator)

        await Self.waitUntil { manager.currentMesh?.name == "Golden" }
        // Both handlers run as spawned tasks; let them drain so a late open of the control would show.
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.currentMesh?.name == "Golden", """
            a manager of another app's namespace did not open metadata sealed under that app's label, or \
            opened the one sealed under Fernlet's: the mesh is named \(manager.currentMesh?.name ?? "nothing")
            """)
    }

    /// Every epoch id is derived under the raw epoch domain of the namespace it is handed: `minted`,
    /// `successor` and both branches of the rotation plan (a first epoch, and a successor of a head)
    /// each yield an id that is SHA-256 over that namespace's `hash.meshEpochIDV1` then the lowercase
    /// mesh id, the big-endian counter and the coordinator — and `.fernlet` and another app's
    /// namespace derive different ids for one epoch.
    @Test func everyEpochIDIsDerivedUnderTheNamespaceItIsHanded() throws {
        let (meshID, coordinator) = (MeshMembershipEventFixtures.meshID, "00000000000000aa")
        var minted: [UUID] = []
        // R2: bounded by the two namespaces.
        for purposes in [ProximityNamespace.Purposes.fernlet, ForeignAppNamespace.namespace().family.purposes] {
            let domain = purposes.hash.meshEpochIDV1
            let head = try #require(MeshEpochRef.minted(counter: 7, coordinatorFingerprint: coordinator, meshID: meshID, in: purposes))
            let next = try #require(head.successor(coordinatorFingerprint: coordinator, meshID: meshID, in: purposes))
            Self.expectDigest(Self.uuidBytes(head.epochID), over: Self.epochTail(meshID: meshID, counter: 7, coordinator: coordinator),
                              by: domain, consumer: "MeshEpochRef.minted(...in:) under \(domain.rawValue)")
            Self.expectDigest(Self.uuidBytes(next.epochID), over: Self.epochTail(meshID: meshID, counter: 8, coordinator: coordinator),
                              by: domain, consumer: "MeshEpochRef.successor(...in:) under \(domain.rawValue)")
            let first = MeshEpochRef.minted(counter: 1, coordinatorFingerprint: coordinator, meshID: meshID, in: purposes)
            #expect(MeshRotationPolicy.plan(head: head, coordinatorFingerprint: coordinator, meshID: meshID,
                                            presentedRoster: [coordinator], in: purposes) == .rotate(next),
                    "the rotation plan under \(domain.rawValue) did not rotate to the successor derived under it")
            #expect(first.map { MeshRotationPolicy.plan(head: nil, coordinatorFingerprint: coordinator, meshID: meshID,
                                                        presentedRoster: [coordinator], in: purposes) == .rotate($0) } == true,
                    "the first rotation under \(domain.rawValue) did not mint the epoch derived under it")
            minted.append(head.epochID)
        }
        #expect(minted.count == 2 && minted[0] != minted[1], "two namespaces derived one epoch id")
    }

    // MARK: Group 12 — the radios (A0.2.7)

    /// The values A0.2.7 moves, read through the radios that consume them. Built from `.fernlet`,
    /// each radio holds its OWN field's frozen service type and ALPN (so no radio reads a sibling's),
    /// and the mesh radio the frozen heartbeat and TLS exporter label, and `.fernlet`'s labels as the
    /// copy its channel introductions are framed and checked under. Built from another app's
    /// namespace, each holds that app's values, so every read is the namespace's field and not a
    /// literal that happens to match Fernlet's. Building a radio starts nothing.
    @Test func theRadiosReadTheirValuesOffTheNamespace() {
        let mesh = NetworkMeshSession(namespace: .fernlet)
        let presence = NetworkPresenceSession(namespace: .fernlet)
        let recipe = NetworkRecipeShareSession(namespace: .fernlet)
        let read: [(field: String, bytes: Data)] = [
            ("family.radios.mesh.serviceType", Data(mesh.serviceType.utf8)),
            ("family.radios.mesh.alpn", Data(mesh.alpn.utf8)),
            ("family.radios.presence.serviceType", Data(presence.serviceType.utf8)),
            ("family.radios.presence.alpn", Data(presence.alpn.utf8)),
            ("family.radios.recipeShare.serviceType", Data(recipe.serviceType.utf8)),
            ("family.radios.recipeShare.alpn", Data(recipe.alpn.utf8)),
            ("family.radios.meshHeartbeat", mesh.heartbeatDatagram),
            ("family.purposes.keyDerivation.meshTLSExporterV1", mesh.tlsExporterLabel.data)
        ]
        // R2: bounded by the eight values.
        for entry in read {
            #expect(entry.bytes == Data(Self.frozen(entry.field).utf8),
                    "a radio built from .fernlet holds \(Self.hex(entry.bytes)) for \(entry.field)")
        }
        #expect(mesh.tlsExporterLabel.role == .tlsExporterLabel, "the exporter label lost its role")
        #expect(mesh.purposes == ProximityNamespace.fernlet.family.purposes,
                "the mesh radio frames its channel introductions under labels other than .fernlet's")

        let foreign = ForeignAppNamespace.namespace()
        let radios = foreign.family.radios
        let foreignMesh = NetworkMeshSession(namespace: foreign)
        let foreignPresence = NetworkPresenceSession(namespace: foreign)
        let foreignRecipe = NetworkRecipeShareSession(namespace: foreign)
        #expect([foreignMesh.serviceType, foreignPresence.serviceType, foreignRecipe.serviceType]
                == [radios.mesh.serviceType, radios.presence.serviceType, radios.recipeShare.serviceType],
                "a radio built from another app's namespace advertises a service type of its own")
        #expect([foreignMesh.alpn, foreignPresence.alpn, foreignRecipe.alpn]
                == [radios.mesh.alpn, radios.presence.alpn, radios.recipeShare.alpn],
                "a radio built from another app's namespace negotiates an ALPN of its own")
        #expect(foreignMesh.heartbeatDatagram == radios.meshHeartbeat, "the heartbeat is not the namespace's")
        #expect(foreignMesh.tlsExporterLabel == foreign.family.purposes.keyDerivation.meshTLSExporterV1,
                "the exporter label is not the namespace's")
        #expect(foreignMesh.purposes == foreign.family.purposes, "the introduction's labels are not the namespace's")
    }

    /// The mesh radio's two consumers of a moved value, against what their fields promise. Tier 1
    /// cannot open the live QUIC connection both run over, so they are pinned in source, the way
    /// `NetworkMeshWireTests` pins the wire ceiling's two call sites:
    ///
    /// - the heartbeat goes out on both pipes as the radio's own `heartbeatDatagram`, and both receive
    ///   loops drop it by byte equality against that same value before anything decodes a frame;
    /// - the channel binding derives under the label it is handed, whole, as the `.tlsExporterLabel`
    ///   role says (its `prefixBytes` are its bytes): the TLS exporter gets the label's bytes and their
    ///   count, no terminator and no count in front. It names no registry purpose, and its one caller
    ///   hands it the label the radio read off its namespace.
    @Test func theMeshRadiosHeartbeatAndChannelBindingTakeTheirValuesWhole() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Transport/NetworkMeshSession.swift"))
        func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        #expect(count("guard payload != heartbeatDatagram else {") == 2,
                "both receive loops must drop the heartbeat by byte equality")
        #expect(count("try await self.sendFramed(self.heartbeatDatagram, over: stream)") == 1,
                "the control-stream beat must send the radio's own heartbeat")
        #expect(count("try await datagrams.send(self.heartbeatDatagram)") == 1,
                "the datagram beat must send the radio's own heartbeat")

        let label = ProximityNamespace.fernlet.family.purposes.keyDerivation.meshTLSExporterV1
        #expect(label.role == .tlsExporterLabel && label.prefixBytes == label.data, "an exporter label is taken whole")
        let binding = try #require(MeshRoutedSourceScan.bracedBody(after: "static func channelBindingHash(", in: code),
                                   "the channel binding's derivation is gone")
        #expect(binding.contains("let label = exporterLabel.rawValue"), "the binding derives under another label")
        #expect(binding.contains("label.utf8.count,"), "the exporter is not handed the label's own byte count")
        #expect(!binding.contains("FernletCryptoPurpose"), "the binding names a registry purpose again")
        #expect(count("Self.channelBindingHash(for: connection, exporterLabel: tlsExporterLabel)") == 1,
                "the introduction no longer binds under the radio's own exporter label")
        #expect(count("tlsExporterLabel = namespace.family.purposes.keyDerivation.meshTLSExporterV1") == 1,
                "the radio no longer reads its exporter label off the namespace")
    }

    // MARK: Group 13 — the at-rest names and rows read the namespace (A0.2.8)

    /// The two sealed mesh stores read their file names and their seal key's account off the namespace
    /// their scope carries, under `.fernlet` and under another app's namespace, on isolated scopes:
    /// the session store saves its context at that namespace's file name and mints its seal key at
    /// that namespace's account, the only row under the scope's service; the routed store does the
    /// same for its index and keeps its chunks under that namespace's chunk directory; and both load
    /// back what they wrote. So every read is the namespace's field and no literal. (Since plan step
    /// A0.2.9 both also seal under that namespace's column labels: group 14 pins those reads.)
    @Test func theStoresReadTheirNamesAndSealKeyAccountsOffTheirScopesNamespace() throws {
        // R2: bounded by the two namespaces.
        for namespace in [ProximityNamespace.fernlet, ForeignAppNamespace.namespace()] {
            let (storage, keychain) = (namespace.installation.storage, namespace.installation.keychain)
            let session = MeshSessionStore(scope: MeshSessionStorageScope(
                namespace: namespace, directory: Self.scratchDirectory(),
                keychainService: "com.fernlet.mesh-session.test.namespacegolden.\(UUID().uuidString)",
                installBinding: FernletDeviceBindingAdapter()))
            let routed = MeshRoutedStore(scope: MeshRoutedStorageScope(
                namespace: namespace, directory: Self.scratchDirectory(),
                keychainService: "com.fernlet.mesh-routed.test.namespacegolden.\(UUID().uuidString)",
                installBinding: FernletDeviceBindingAdapter()))
            defer {
                MeshSessionStoreFixtures.tearDown(session.scope)
                MeshRoutedStoreFixtures.tearDown(routed.scope)
            }
            try MeshSessionStoreFixtures.save(MeshSessionStoreFixtures.context(), into: session)
            try MeshRoutedStoreFixtures.save(MeshRoutedIndex(), into: routed)
            let directory = storage.directoryName
            let (sessionNames, routedNames) = (try Self.names(in: session.scope.directory), try Self.names(in: routed.scope.directory))
            #expect(sessionNames == [storage.meshSessionContextFileName],
                    "the session store under \(directory)'s names wrote \(sessionNames)")
            #expect(Self.accounts(under: session.scope.keychainService) == [keychain.meshSessionSealKey.account],
                    "the session store under \(directory)'s names sealed under another account")
            #expect(routedNames == [storage.meshRoutedIndexFileName],
                    "the routed store under \(directory)'s names wrote \(routedNames)")
            #expect(routed.chunkDirectory == routed.scope.directory.appendingPathComponent(
                storage.meshRoutedChunkDirectoryName, isDirectory: true), "the chunks moved: \(routed.chunkDirectory.path)")
            #expect(Self.accounts(under: routed.scope.keychainService) == [keychain.meshRoutedSealKey.account],
                    "the routed store under \(directory)'s names sealed under another account")
            let loads = DeviceBindingID.$testOverride.withValue(.identifier(MeshSessionStoreFixtures.installA)) {
                (session: session.load(), routed: routed.load())
            }
            guard case .loaded = loads.session, case .loaded = loads.routed else {
                Issue.record("a store under \(directory)'s names did not load what it wrote: \(loads)")
                continue
            }
        }
    }

    /// A host that carries no sidecar root or scope of its own gets them built from its namespace:
    /// the root is the namespace's `installation.storage.defaultDirectory`, and on it both scopes carry
    /// the namespace and its production seal-key services; a host on another root keeps the namespace
    /// and gets services named after that root. Under `.fernlet` that is `Application Support/Fernlet`
    /// with Fernlet's frozen services; under another app's namespace, that app's. Building a host or a
    /// scope touches no disk and no keychain.
    @Test func aHostsDefaultRootAndScopesAreBuiltFromItsNamespace() {
        // R2: bounded by the two namespaces.
        for namespace in [ProximityNamespace.fernlet, ForeignAppNamespace.namespace()] {
            let keychain = namespace.installation.keychain
            let host = NamespaceDefaultsHost(namespace: namespace)
            let root = namespace.installation.storage.defaultDirectory
            #expect(host.proximitySupportDirectory == root, "the default root is \(host.proximitySupportDirectory.path)")
            let (session, routed) = (host.meshSessionStorage, host.meshRoutedStorage)
            #expect(session.namespace == namespace && session.directory == root
                        && session.keychainService == keychain.meshSessionSealKey.service,
                    "the default session scope on the namespace's root is \(session.keychainService)")
            #expect(routed.namespace == namespace && routed.directory == root
                        && routed.keychainService == keychain.meshRoutedSealKey.service,
                    "the default routed scope on the namespace's root is \(routed.keychainService)")
            let rooted = RootedNamespaceDefaultsHost(namespace: namespace, root: Self.scratchDirectory())
            let suffix = ".host." + rooted.proximitySupportDirectory.lastPathComponent
            #expect(rooted.meshSessionStorage.namespace == namespace
                        && rooted.meshSessionStorage.keychainService == keychain.meshSessionSealKey.service + suffix,
                    "a host on its own root shares the session seal-key row: \(rooted.meshSessionStorage.keychainService)")
            #expect(rooted.meshRoutedStorage.namespace == namespace
                        && rooted.meshRoutedStorage.keychainService == keychain.meshRoutedSealKey.service + suffix,
                    "a host on its own root shares the routed seal-key row: \(rooted.meshRoutedStorage.keychainService)")
        }
        let fernlet = NamespaceDefaultsHost(namespace: .fernlet)
        #expect(fernlet.meshSessionStorage.keychainService == Self.frozen("installation.keychain.meshSessionSealKey.service")
                    && fernlet.meshRoutedStorage.keychainService == Self.frozen("installation.keychain.meshRoutedSealKey.service"),
                "a Fernlet host's default scopes left Fernlet's production rows")
    }

    /// An identity keeps, and its provisioning rule names, the four device rows its namespace names.
    /// One of another app's namespace, on an isolated service, writes exactly that app's four accounts
    /// (one of `.fernlet` writes the frozen four: group 1); and under Fernlet's accounts and that app's,
    /// the rule names an unreadable signing row and an unparseable key-agreement row by the accounts
    /// it is handed.
    @Test func anIdentityKeepsAndNamesTheRowsItsNamespaceNames() throws {
        let foreign = ForeignAppNamespace.namespace().installation.keychain.identity
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        try IdentityService(namespace: ForeignAppNamespace.namespace(), keychainService: service).ensureProvisioned()
        let written = Set(KeychainItem.loadAll(service: service).map { $0.account })
        let named: Set = [foreign.signingPrivateKey, foreign.keyAgreementPrivateKey, foreign.signingPublicKeyCache,
                          foreign.keyAgreementPublicKeyCache]
        #expect(written == named, "an identity of another app wrote \(written.sorted()), not \(named.sorted())")
        let signing = Curve25519.Signing.PrivateKey().rawRepresentation
        // R2: bounded by the two namespaces.
        for accounts in [ProximityNamespace.fernlet.installation.keychain.identity, foreign] {
            let unreadable = IdentityService.classifyDeviceIdentityRows(
                signing: .unreadable(errSecIO), keyAgreement: .absent, accounts: accounts)
            let unparseable = IdentityService.classifyDeviceIdentityRows(
                signing: .found(signing), keyAgreement: .found(Data([1, 2, 3])), accounts: accounts)
            guard case .unreadable(let row, _) = unreadable, case .unparseable(let badRow) = unparseable else {
                Issue.record("the rule did not refuse by row: \(unreadable), \(unparseable)")
                continue
            }
            #expect(row == accounts.signingPrivateKey && badRow == accounts.keyAgreementPrivateKey,
                    "the rule named \(row) and \(badRow), not the accounts it was handed")
        }
    }

    // MARK: Group 14 — the column seal and the install binding (A0.2.9)

    /// One mesh column as ProximityKit's copy reads it (`.fernlet`'s field, as each store reads it off
    /// its scope's namespace) beside FernletCrypto's twin, with group 2's A0.2.0 vectors.
    private struct CopiedColumn {
        let name: String
        let purpose: ProximityCryptographicPurpose
        let twin: CryptographicPurpose
        let columnKeyHex: String
        let blobHex: String
    }

    /// The two mesh columns, through `.fernlet`'s fields.
    private static var copiedColumns: [CopiedColumn] {
        let derivation = ProximityNamespace.fernlet.family.purposes.keyDerivation
        return [
            CopiedColumn(name: "session-context", purpose: derivation.meshSessionContextV1,
                         twin: FernletCryptoPurpose.KeyDerivation.meshSessionContextV1,
                         columnKeyHex: sessionColumnKeyHex, blobHex: sessionColumnBlobHex),
            CopiedColumn(name: "routed-store", purpose: derivation.meshRoutedStoreV1,
                         twin: FernletCryptoPurpose.KeyDerivation.meshRoutedStoreV1,
                         columnKeyHex: routedColumnKeyHex, blobHex: routedColumnBlobHex)
        ]
    }

    /// The second install every group 14 cell tells apart from `installBinding`: `B9` × 16
    /// (`MeshSessionStoreFixtures.installB`).
    static let otherInstallBinding = Data(repeating: 0xB9, count: 16)

    /// The copy derives group 2's two known column keys from `.fernlet`'s two column-seal fields: the
    /// label is the salt-free HKDF's `info`, whole, as in FernletCrypto's `ColumnCrypto`.
    @Test func theCopiedColumnSealDerivesTheKnownColumnKeys() {
        // R2: bounded by the two columns.
        for column in Self.copiedColumns {
            #expect(column.purpose.role == .columnSeal, "the \(column.name) field is not a column seal")
            let key = ProximityColumnCrypto.deriveColumnKey(contentKey: Self.columnContentKey, purpose: column.purpose,
                                                            outputByteCount: 32)
            let actual = Self.hex(key.withUnsafeBytes { Data($0) })
            #expect(actual == column.columnKeyHex, "the copy's \(column.name) column key moved — actual hex = \(actual)")
        }
    }

    /// The copy opens group 2's two known V3 blobs, built from the literal labels, under the pinned
    /// binding — which reaches it through Fernlet's adapter, from `DeviceBindingID`'s task-local seam.
    @Test func theCopiedColumnSealOpensTheKnownColumnBlobs() throws {
        try DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            // R2: bounded by the two columns.
            for column in Self.copiedColumns {
                let blob = try #require(Self.bytes(hex: column.blobHex))
                let copy = ProximityColumnCrypto(purpose: column.purpose, installBinding: FernletDeviceBindingAdapter())
                let opened: [String]? = try copy.open(blob, contentKey: Self.columnContentKey)
                #expect(opened == ["golden"], "the copy did not open the known \(column.name) blob")
            }
        }
    }

    /// Byte for byte, both ways: for both labels, a blob the copy seals is `0x03` ‖ nonce ‖ ciphertext ‖
    /// tag and opens with FernletCrypto's `ColumnCrypto`, and a blob `ColumnCrypto` seals opens with
    /// the copy — so every mesh file written before step A0.2.9 opens after it, and every one written
    /// after it opens with the code before.
    @Test func theCopyAndFernletCryptosColumnCryptoOpenEachOthersBlobs() throws {
        let plaintext = ["golden", "both ways"]
        let plaintextByteCount = try JSONEncoder().encode(plaintext).count
        try DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            // R2: bounded by the two columns.
            for column in Self.copiedColumns {
                let copy = ProximityColumnCrypto(purpose: column.purpose, installBinding: FernletDeviceBindingAdapter())
                let original = ColumnCrypto(purpose: column.twin)
                let byCopy = try copy.seal(plaintext, contentKey: Self.columnContentKey)
                let byOriginal = try original.seal(plaintext, contentKey: Self.columnContentKey)
                #expect(byCopy.first == 0x03 && byCopy.count == 1 + 12 + plaintextByteCount + 16,
                        "the copy wrote a \(byCopy.count)-byte \(column.name) blob starting \(Self.hex(byCopy.prefix(1)))")
                let openedByOriginal: [String]? = try original.open(byCopy, contentKey: Self.columnContentKey)
                let openedByCopy: [String]? = try copy.open(byOriginal, contentKey: Self.columnContentKey)
                #expect(openedByOriginal == plaintext, "ColumnCrypto did not open the copy's \(column.name) blob")
                #expect(openedByCopy == plaintext, "the copy did not open ColumnCrypto's \(column.name) blob")
            }
        }
    }

    /// The copy refuses exactly where FernletCrypto's `ColumnCrypto` refuses, and by the same name. For
    /// both labels, five blobs (a good V3 blob, one tampered with, a `0x02` blob, an unprefixed one and
    /// an empty one) are opened under four answers of the install binding (this install, another one,
    /// an absent row, a failed read), and the two verdicts agree in all forty pairings: a retired
    /// format is named before the binding is read, an absent row refuses, a failed read is the
    /// retryable error carrying the same status, and another install fails authentication. And under an
    /// absent row or a failed read, both seals refuse.
    @Test func theCopyRefusesExactlyWhereFernletCryptosColumnCryptoRefuses() throws {
        let overrides: [DeviceBindingID.TestOverride] = [
            .identifier(Self.installBinding), .identifier(Self.otherInstallBinding), .unavailable, .readError
        ]
        var compared = 0
        // R2: bounded by the two columns, five blobs and four answers.
        for column in Self.copiedColumns {
            let copy = ProximityColumnCrypto(purpose: column.purpose, installBinding: FernletDeviceBindingAdapter())
            let original = ColumnCrypto(purpose: column.twin)
            for blob in try Self.refusalBlobs(sealedBy: original) {
                for answer in overrides {
                    let verdicts = DeviceBindingID.$testOverride.withValue(answer) {
                        (copy: Self.verdict(of: copy, opening: blob), original: Self.verdict(of: original, opening: blob))
                    }
                    #expect(verdicts.copy == verdicts.original,
                            "\(column.name), \(answer): the copy said \(verdicts.copy), ColumnCrypto \(verdicts.original)")
                    compared += 1
                }
            }
            for answer in [DeviceBindingID.TestOverride.unavailable, .readError] {
                DeviceBindingID.$testOverride.withValue(answer) {
                    #expect(throws: ProximityColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                        try copy.seal(["golden"], contentKey: Self.columnContentKey)
                    }
                    #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                        try original.seal(["golden"], contentKey: Self.columnContentKey)
                    }
                }
            }
        }
        #expect(compared == 40, "the refusal matrix compared \(compared) pairings")
        let routedBlobs = try Self.refusalBlobs(sealedBy: ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.meshRoutedStoreV1))
        let anchor = try #require(routedBlobs.first)
        let readError = DeviceBindingID.$testOverride.withValue(.readError) {
            Self.verdict(of: ProximityColumnCrypto(purpose: ProximityNamespace.fernlet.family.purposes.keyDerivation.meshRoutedStoreV1,
                                                   installBinding: FernletDeviceBindingAdapter()), opening: anchor)
        }
        #expect(readError == .bindingReadError(errSecIO), "a failed binding read was not the retryable error: \(readError)")
    }

    /// Each sealed mesh store seals under its scope namespace's column label and its scope's install
    /// binding, and under nothing else. On a scope carrying a binding of the test's own (`A7`) while
    /// `DeviceBindingID` answers another (`B9`), under `.fernlet` and under another app's namespace,
    /// the context file and the routed index the two stores write open under that namespace's label
    /// and `A7`, and under neither the other namespace's label nor `B9`.
    @Test func theStoresSealUnderTheirScopesColumnLabelAndInstallBinding() throws {
        let namespaces = [ProximityNamespace.fernlet, ForeignAppNamespace.namespace()]
        // R2: bounded by the two namespaces.
        for (index, namespace) in namespaces.enumerated() {
            let pinned = PinnedInstallBinding(bytes: Self.installBinding)
            let session = MeshSessionStore(scope: MeshSessionStorageScope(
                namespace: namespace, directory: Self.scratchDirectory(),
                keychainService: "com.fernlet.mesh-session.test.namespacegolden.\(UUID().uuidString)", installBinding: pinned))
            let routed = MeshRoutedStore(scope: MeshRoutedStorageScope(
                namespace: namespace, directory: Self.scratchDirectory(),
                keychainService: "com.fernlet.mesh-routed.test.namespacegolden.\(UUID().uuidString)", installBinding: pinned))
            defer {
                MeshSessionStoreFixtures.tearDown(session.scope)
                MeshRoutedStoreFixtures.tearDown(routed.scope)
            }
            try MeshSessionStoreFixtures.save(MeshSessionStoreFixtures.context(), into: session, install: Self.otherInstallBinding)
            try MeshRoutedStoreFixtures.save(MeshRoutedIndex(), into: routed, install: Self.otherInstallBinding)
            let keychain = namespace.installation.keychain
            guard case .available(let sessionKey) = MeshSessionSealKey.forOpen(
                      service: session.scope.keychainService, account: keychain.meshSessionSealKey.account),
                  case .available(let routedKey) = MeshRoutedSealKey.forOpen(
                      service: routed.scope.keychainService, account: keychain.meshRoutedSealKey.account) else {
                Issue.record("a store under \(namespace.installation.storage.directoryName)'s names minted no seal key")
                continue
            }
            let (labels, other) = (namespace.family.purposes.keyDerivation, namespaces[1 - index].family.purposes.keyDerivation)
            let sessionBlob = try Data(contentsOf: session.fileURL)
            let routedBlob = try Data(contentsOf: routed.indexURL)
            #expect(Self.sealedUnder(sessionBlob, as: MeshSessionContext.self, key: sessionKey,
                                     label: labels.meshSessionContextV1, otherLabel: other.meshSessionContextV1))
            #expect(Self.sealedUnder(routedBlob, as: MeshRoutedIndex.self, key: routedKey,
                                     label: labels.meshRoutedStoreV1, otherLabel: other.meshRoutedStoreV1))
        }
    }

    /// Fernlet's adapter answers `DeviceBindingID` at each call and keeps nothing: a seal reads
    /// `current()` (this install, `nil` for an absent row and for a failed read), an open reads
    /// `currentForOpen()` (this install, `nil` for an absent row, the retryable error carrying
    /// `errSecIO` for a failed read), and a scripted answer flipped between two reads is what the
    /// second read sees — the seam the mid-operation flip in `MeshSessionLifecycleManagerTests` rides.
    @Test func fernletsAdapterAnswersDeviceBindingIDAtEachCall() throws {
        let adapter = FernletDeviceBindingAdapter()
        let pinned = try DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            (seal: try adapter.read(for: .seal), open: try adapter.read(for: .open))
        }
        #expect(pinned.seal == Self.installBinding && pinned.open == Self.installBinding, "\(pinned)")
        let absent = try DeviceBindingID.$testOverride.withValue(.unavailable) {
            (seal: try adapter.read(for: .seal), open: try adapter.read(for: .open))
        }
        #expect(absent.seal == nil && absent.open == nil, "an absent row answered \(absent)")
        let sealThroughFailedRead = try DeviceBindingID.$testOverride.withValue(.readError) { try adapter.read(for: .seal) }
        #expect(sealThroughFailedRead == nil, "a seal read a binding through a failed read")
        DeviceBindingID.$testOverride.withValue(.readError) {
            #expect(throws: ProximityInstallBindingReadError(status: errSecIO)) { try adapter.read(for: .open) }
        }
        let scripted = DeviceBindingID.ScriptedBinding(.identifier(Self.installBinding))
        let reads: (before: Data?, after: Data?) = try DeviceBindingID.$testOverride.withValue(.scripted(scripted)) {
            let before = try adapter.read(for: .open)
            scripted.set(.identifier(Self.otherInstallBinding))
            return (before: before, after: try adapter.read(for: .open))
        }
        #expect(reads.before == Self.installBinding && reads.after == Self.otherInstallBinding,
                "the adapter kept an answer DeviceBindingID changed: \(reads)")
    }

    /// A host's default storage scopes carry the install binding the host supplies, on the namespace's
    /// root and on a root of its own, so the stores a manager builds over them seal under the host's
    /// binding. Building a host or a scope reads no binding.
    @Test func aHostsDefaultScopesCarryTheInstallBindingItSupplies() throws {
        let supplied = PinnedInstallBinding(bytes: Self.otherInstallBinding)
        let host = NamespaceDefaultsHost(namespace: .fernlet, installBinding: supplied)
        let rooted = RootedNamespaceDefaultsHost(namespace: .fernlet, root: Self.scratchDirectory(), installBinding: supplied)
        let carried: [any ProximityInstallBinding] = [
            host.meshSessionStorage.installBinding, host.meshRoutedStorage.installBinding,
            rooted.meshSessionStorage.installBinding, rooted.meshRoutedStorage.installBinding
        ]
        // R2: bounded by the four scopes.
        for binding in carried {
            #expect(try binding.read(for: .open) == Self.otherInstallBinding, "a default scope carries another binding")
        }
    }

    /// What opening one blob came to, spelled alike for the copy and FernletCrypto's `ColumnCrypto`, so
    /// the two can be compared verdict for verdict.
    private enum ColumnOpenVerdict: Equatable {
        /// The blob opened.
        case opened([String]?)
        /// A retired format, named by its marker bucket.
        case retired(String)
        /// An empty blob.
        case emptyBlob
        /// An authoritatively absent install binding.
        case installBindingMissing
        /// A failed binding read, with its status.
        case bindingReadError(OSStatus)
        /// Anything else: CryptoKit's authentication failure.
        case authenticationFailed
    }

    /// Five blobs for the refusal matrix: a good V3 blob `original` seals under `installBinding`, the
    /// same with its last byte flipped, 96 bytes of `0x02`, an unprefixed blob and an empty one.
    private static func refusalBlobs(sealedBy original: ColumnCrypto) throws -> [Data] {
        let good = try DeviceBindingID.$testOverride.withValue(.identifier(installBinding)) {
            try original.seal(["golden"], contentKey: columnContentKey)
        }
        var tampered = good
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        return [good, tampered, Data(repeating: 0x02, count: 96), Data([0x05]) + sequence(from: 0x40, count: 40), Data()]
    }

    /// The copy's verdict on `blob`.
    private static func verdict(of copy: ProximityColumnCrypto, opening blob: Data) -> ColumnOpenVerdict {
        do {
            let opened: [String]? = try copy.open(blob, contentKey: columnContentKey)
            return .opened(opened)
        } catch ProximityColumnCrypto.SealedColumnOpenError.retiredFormat(let format) {
            return .retired(String(describing: format))
        } catch ProximityColumnCrypto.SealedColumnOpenError.emptyBlob {
            return .emptyBlob
        } catch ProximityColumnCrypto.SealedColumnOpenError.installBindingMissing {
            return .installBindingMissing
        } catch let error as ProximityInstallBindingReadError {
            return .bindingReadError(error.status)
        } catch {
            return .authenticationFailed
        }
    }

    /// FernletCrypto's `ColumnCrypto`'s verdict on `blob`.
    private static func verdict(of original: ColumnCrypto, opening blob: Data) -> ColumnOpenVerdict {
        do {
            let opened: [String]? = try original.open(blob, contentKey: columnContentKey)
            return .opened(opened)
        } catch ColumnCrypto.SealedColumnOpenError.retiredFormat(let format) {
            return .retired(format.rawValue)
        } catch ColumnCrypto.SealedColumnOpenError.emptyBlob {
            return .emptyBlob
        } catch ColumnCrypto.SealedColumnOpenError.installBindingMissing {
            return .installBindingMissing
        } catch let error as DeviceBindingID.ReadError {
            return .bindingReadError(error.status)
        } catch {
            return .authenticationFailed
        }
    }

    /// Whether `blob`, sealed under `key`, opens as a `T` under `label` and `installBinding`, and
    /// under neither `otherLabel` nor `otherInstallBinding`.
    private static func sealedUnder<T: Decodable>(
        _ blob: Data, as type: T.Type, key: SymmetricKey,
        label: ProximityCryptographicPurpose, otherLabel: ProximityCryptographicPurpose
    ) -> Bool {
        func opens(_ label: ProximityCryptographicPurpose, _ binding: Data) -> Bool {
            let seal = ProximityColumnCrypto(purpose: label, installBinding: PinnedInstallBinding(bytes: binding))
            do {
                let opened: T? = try seal.open(blob, contentKey: key)
                return opened != nil
            } catch {
                return false
            }
        }
        let expected = opens(label, installBinding)
        let underOtherLabel = opens(otherLabel, installBinding)
        let underOtherInstall = opens(label, otherInstallBinding)
        if !expected || underOtherLabel || underOtherInstall {
            Issue.record("""
                a \(T.self) blob opened under its label and binding: \(expected), under \(otherLabel.rawValue): \
                \(underOtherLabel), under the other install: \(underOtherInstall)
                """)
        }
        return expected && !underOtherLabel && !underOtherInstall
    }

    // MARK: Group 15 — the keychain mechanism (A0.2.11)

    /// The keychain rows `.fernlet` names, as ProximityKit keeps them: the identity's four device rows
    /// and the two seal-key rows, each stored `AfterFirstUnlockThisDeviceOnly` and never synchronized.
    private static var fernletKeychainRows: [ProximityNamespace.Keychain.Row] {
        let keychain = ProximityNamespace.fernlet.installation.keychain
        let identity = keychain.identity
        let accounts = [identity.signingPrivateKey, identity.keyAgreementPrivateKey, identity.signingPublicKeyCache,
                        identity.keyAgreementPublicKeyCache]
        return accounts.map { ProximityNamespace.Keychain.Row(service: identity.service, account: $0) }
            + [keychain.meshSessionSealKey, keychain.meshRoutedSealKey]
    }

    /// For every keychain row `.fernlet` names, each query dictionary ProximityKit's copy issues is the
    /// one FernletFoundation's `KeychainItem` issues for the same service and account: read out of
    /// `KeychainHelpers.swift` itself and evaluated for that row, then compared key for key and value
    /// for value. Per row: the add (under the row's class, never synchronized), the whole-service
    /// delete, and under each of the three scopes the read behind `load`, the read behind
    /// `loadDistinguishingAbsence`, the enumeration and the delete; 14 a row, 84 in all. A key or value
    /// FernletFoundation's source spells that the evaluation does not know fails the cell.
    @Test func theCopysQueryForEveryNamespaceRowIsFernletFoundationsDictionary() throws {
        let original = FernletFoundationKeychainQueries(
            source: try RepoRoot.source("FernletKit/Sources/FernletFoundation/KeychainHelpers.swift"))
        let (data, deviceOnly) = (Self.sequence(from: 0x20), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        let scopes: [(String, ProximityKeychainItem.SynchronizableScope)] = [("any", .any), ("synced", .synced), ("local", .local)]
        var compared = 0
        // R2: bounded by the six rows and the three scopes.
        for row in Self.fernletKeychainRows {
            let (service, account) = (row.service, row.account)
            let call: [String: Any] = ["service": service, "account": account, "data": data,
                                       "accessibility": deviceOnly, "synchronizable": false]
            var pairs: [(member: String, original: [String: Any]?, copy: [String: Any])] = [
                ("store", original.query("store", call), ProximityKeychainItem.addQuery(
                    data, account: account, service: service, accessibility: deviceOnly, synchronizable: false)),
                ("deleteAllReportingStatus", original.query("deleteAllReportingStatus", call),
                 ProximityKeychainItem.deleteAllQuery(service: service))
            ]
            for (name, scope) in scopes {
                let scoped = call.merging(["scope": name]) { $1 }
                let read = ProximityKeychainItem.readQuery(account: account, service: service, synchronizable: scope)
                pairs += [
                    ("load", original.query("load", scoped), read),
                    ("loadDistinguishingAbsence", original.query("loadDistinguishingAbsence", scoped), read),
                    ("loadAllDistinguishingFailure", original.query("loadAllDistinguishingFailure", scoped),
                     ProximityKeychainItem.enumerationQuery(service: service, synchronizable: scope)),
                    ("deleteReportingStatus", original.query("deleteReportingStatus", scoped),
                     ProximityKeychainItem.deleteQuery(account: account, service: service, synchronizable: scope))
                ]
            }
            for pair in pairs {
                compared += 1
                let same = pair.original.map { NSDictionary(dictionary: pair.copy).isEqual(to: $0) } ?? false
                #expect(same, """
                    \(account) under \(service): the copy's \(pair.member) query is \(pair.copy), \
                    FernletFoundation's is \(pair.original.map { "\($0)" } ?? "not evaluable")
                    """)
            }
        }
        #expect(compared == 84, "the query comparison covered \(compared) dictionaries")
    }

    /// On an isolated service, ProximityKit's copy and FernletFoundation's `KeychainItem` share one
    /// device-only row, as rows written before step A0.2.11 and a host's own cleanup need: the copy
    /// stores it, both read it back, `loadAll` and `loadAllDistinguishingFailure` list it alone, and
    /// the keychain holds it `AfterFirstUnlockThisDeviceOnly` and unsynchronized; a second `store`
    /// replaces it in place; FernletFoundation deletes it and the copy finds it absent and the
    /// service empty; FernletFoundation stores one under the same class, which the copy reads and
    /// deletes; and an emptied service still deletes cleanly.
    @Test func theCopyAndFernletFoundationShareOneDeviceOnlyRow() {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let account = ProximityNamespace.fernlet.installation.keychain.meshSessionSealKey.account
        let (first, second, third) = (Self.sequence(from: 0x10), Self.sequence(from: 0x30), Self.sequence(from: 0x50))
        let deviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #expect(ProximityKeychainItem.store(first, account: account, service: service, accessibility: deviceOnly) == errSecSuccess)
        #expect(ProximityKeychainItem.load(account: account, service: service) == first)
        #expect(Self.spelled(ProximityKeychainItem.loadDistinguishingAbsence(account: account, service: service))
                    == "found \(Self.hex(first))")
        #expect(Self.spelled(KeychainItem.loadDistinguishingAbsence(account: account, service: service))
                    == "found \(Self.hex(first))", "FernletFoundation did not read the copy's row")
        #expect(ProximityKeychainItem.loadAll(service: service).map { $0.account } == [account])
        #expect(Self.spelled(ProximityKeychainItem.loadAllDistinguishingFailure(service: service))
                    == "rows \(account)=\(Self.hex(first))")
        let stored = Self.storedClass(account: account, service: service)
        #expect(stored == StoredKeychainClass(accessible: deviceOnly as String, synchronizable: false),
                "the copy stored its row as \(String(describing: stored))")
        #expect(ProximityKeychainItem.store(second, account: account, service: service, accessibility: deviceOnly) == errSecSuccess)
        #expect(KeychainItem.loadAll(service: service).map { $0.data } == [second], "a second store did not replace the row")
        #expect(KeychainItem.deleteReportingStatus(account: account, service: service) == errSecSuccess)
        #expect(Self.spelled(ProximityKeychainItem.loadDistinguishingAbsence(account: account, service: service)) == "absent")
        #expect(Self.spelled(ProximityKeychainItem.loadAllDistinguishingFailure(service: service)) == "rows ")
        #expect(KeychainItem.store(third, account: account, service: service, accessibility: deviceOnly) == errSecSuccess)
        #expect(Self.storedClass(account: account, service: service) == stored, "FernletFoundation stored another class")
        #expect(ProximityKeychainItem.load(account: account, service: service) == third)
        #expect(ProximityKeychainItem.deleteReportingStatus(account: account, service: service) == errSecSuccess)
        #expect(Self.spelled(KeychainItem.loadDistinguishingAbsence(account: account, service: service)) == "absent")
        #expect(ProximityKeychainItem.deleteAllReportingStatus(service: service) == errSecSuccess, "an empty slot is a cleared slot")
    }

    /// A device-only row and its synchronized twin under one account and service, the two the
    /// identity's escrow reconciliation tells apart, are matched alike by ProximityKit's copy and
    /// FernletFoundation's `KeychainItem` under every scope: the copy writes the twin with
    /// `replacing: .synced`, which leaves the device-only row in place; `.synced` and `.local` each
    /// find exactly their own row through either, and `.any` both; a `.local` delete through the copy
    /// leaves FernletFoundation the synced row alone; and `deleteAll` through the copy clears both.
    @Test func theCopyAndFernletFoundationMatchEachSynchronizableVariantAlike() {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let account = "backupEscrowPrivateKey.k.namespacegolden"
        let (local, synced) = (Self.sequence(from: 0x70), Self.sequence(from: 0x90))
        #expect(ProximityKeychainItem.store(local, account: account, service: service,
                                            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) == errSecSuccess)
        #expect(ProximityKeychainItem.store(synced, account: account, service: service,
                                            accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true,
                                            replacing: .synced) == errSecSuccess)
        let scopes: [(ProximityKeychainItem.SynchronizableScope, KeychainItem.SynchronizableScope, [Data])] = [
            (.synced, .synced, [synced]), (.local, .local, [local]), (.any, .any, [local, synced])
        ]
        // R2: bounded by the three scopes.
        for (scope, originalScope, expected) in scopes {
            let byCopy = ProximityKeychainItem.loadAll(service: service, synchronizable: scope).map { $0.data }
            let byOriginal = KeychainItem.loadAll(service: service, synchronizable: originalScope).map { $0.data }
            #expect(Set(byCopy) == Set(expected) && byCopy.count == expected.count, "the copy's \(scope) listed \(byCopy)")
            #expect(Set(byOriginal) == Set(byCopy) && byOriginal.count == byCopy.count,
                    "FernletFoundation's \(originalScope) listed \(byOriginal), the copy's \(byCopy)")
            if expected.count == 1 {
                #expect(ProximityKeychainItem.load(account: account, service: service, synchronizable: scope) == expected.first)
                #expect(KeychainItem.load(account: account, service: service, synchronizable: originalScope) == expected.first)
            }
        }
        #expect(ProximityKeychainItem.deleteReportingStatus(account: account, service: service, synchronizable: .local) == errSecSuccess)
        #expect(KeychainItem.load(account: account, service: service, synchronizable: .local) == nil)
        #expect(KeychainItem.load(account: account, service: service, synchronizable: .synced) == synced,
                "a .local delete through the copy removed the synced twin")
        ProximityKeychainItem.deleteAll(service: service)
        #expect(KeychainItem.loadAll(service: service).isEmpty, "deleteAll left a variant behind")
    }

    /// ProximityKit's copy fails exactly where FernletFoundation's `KeychainItem` fails, with the same
    /// answer, and audits the two delete failures with FernletFoundation's lines. Every empty-name
    /// guard answers what the original answers (`errSecParam`, `nil`, `.unreadable(errSecParam)`); the
    /// enumeration classifier answers alike for a success carrying rows (one of them not a row, which
    /// both drop), a success without them, an empty slot, and three failing statuses, among them
    /// `errSecInteractionNotAllowed`, which no simulator keychain can be made to return; and a failed
    /// `delete` and `deleteAll` reach `FernletAuditLog`, through the bridge the app installs, as exactly
    /// the `keychain.delete.failed` and `keychain.deleteAll.failed` lines the original writes.
    @Test func theCopyFailsAndAuditsExactlyWhereFernletFoundationsKeychainItemDoes() {
        let service = Self.isolatedIdentityService()
        let deviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #expect(ProximityKeychainItem.store(Data([1]), account: "", service: service, accessibility: deviceOnly) == errSecParam
                    && KeychainItem.store(Data([1]), account: "", service: service, accessibility: deviceOnly) == errSecParam)
        #expect(ProximityKeychainItem.store(Data(), account: "row", service: service, accessibility: deviceOnly) == errSecParam
                    && KeychainItem.store(Data(), account: "row", service: service, accessibility: deviceOnly) == errSecParam)
        #expect(ProximityKeychainItem.load(account: "row", service: "") == nil && KeychainItem.load(account: "row", service: "") == nil)
        // R2: bounded by the two empty-name pairs.
        for (account, named) in [("", service), ("row", "")] {
            #expect(Self.spelled(ProximityKeychainItem.loadDistinguishingAbsence(account: account, service: named))
                        == Self.spelled(KeychainItem.loadDistinguishingAbsence(account: account, service: named)))
            #expect(ProximityKeychainItem.deleteReportingStatus(account: account, service: named)
                        == KeychainItem.deleteReportingStatus(account: account, service: named))
        }
        #expect(Self.spelled(ProximityKeychainItem.loadAllDistinguishingFailure(service: ""))
                    == Self.spelled(KeychainItem.loadAllDistinguishingFailure(service: "")))
        #expect(ProximityKeychainItem.deleteAllReportingStatus(service: "") == KeychainItem.deleteAllReportingStatus(service: ""))
        let matches: [[String: Any]] = [[kSecAttrAccount as String: "row", kSecValueData as String: Data([7])],
                                        [kSecAttrAccount as String: "dataless"]]
        let enumerations: [(OSStatus, [[String: Any]]?)] = [
            (errSecSuccess, matches), (errSecSuccess, nil), (errSecItemNotFound, nil),
            (errSecInteractionNotAllowed, nil), (errSecNotAvailable, nil), (errSecIO, nil)
        ]
        // R2: bounded by the six enumeration outcomes.
        for (status, given) in enumerations {
            let copy = Self.spelled(ProximityKeychainItem.enumerationResult(status: status, matches: given))
            #expect(copy == Self.spelled(KeychainItem.enumerationResult(status: status, matches: given)),
                    "status \(status): the copy classified \(copy)")
        }
        let byCopy = KeychainAuditLines.delivered {
            ProximityKeychainItem.delete(account: "", service: service)
            ProximityKeychainItem.deleteAll(service: "")
        }
        let byOriginal = KeychainAuditLines.delivered {
            KeychainItem.delete(account: "", service: service)
            KeychainItem.deleteAll(service: "")
        }
        let written = [
            KeychainAuditLines.Line(event: "keychain.delete.failed",
                                    context: ["service": service, "account": "", "status": "\(errSecParam)"]),
            KeychainAuditLines.Line(event: "keychain.deleteAll.failed", context: ["service": "", "status": "\(errSecParam)"])
        ]
        #expect(byOriginal == written, "FernletFoundation's delete lines are \(byOriginal)")
        #expect(byCopy == byOriginal, "the copy's delete lines are \(byCopy), FernletFoundation's \(byOriginal)")
    }

    /// ProximityKit's code reaches the keychain through its own copy and names FernletFoundation's
    /// `KeychainItem` nowhere, so the move is whole: a call that went back to the original, from a
    /// file that still imports FernletFoundation for something else, fails here. Comments may name
    /// `KeychainItem` (the copy's own explain where it came from); the scan reads code lines only.
    @Test func proximityKitReachesTheKeychainOnlyThroughItsOwnCopy() throws {
        let root = RepoRoot.url("FernletKit/Sources/ProximityKit")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        let original = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])KeychainItem\b"#)
        var copyUses = 0
        var offenders: [String] = []
        // R2: bounded by the module's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            let code = MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            copyUses += code.components(separatedBy: "ProximityKeychainItem.").count - 1
            if original.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(files.count >= 50, "the ProximityKit sweep read only \(files.count) Swift files")
        #expect(copyUses > 0, "the sweep found no `ProximityKeychainItem.` use: wrong tree?")
        #expect(offenders.isEmpty, """
            ProximityKit code names FernletFoundation's KeychainItem in \(offenders). Reach the keychain \
            through `ProximityKeychainItem`, which issues the same queries.
            """)
    }

    /// A row's class and synchronizable flag as the keychain itself holds them.
    private struct StoredKeychainClass: Equatable {
        /// `kSecAttrAccessible`.
        let accessible: String
        /// `kSecAttrSynchronizable`.
        let synchronizable: Bool
    }

    /// The class and flag of the one `account` row under `service`, read back from the keychain, or nil.
    private static func storedClass(account: String, service: String) -> StoredKeychainClass? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let accessible = attributes[kSecAttrAccessible as String] as? String else { return nil }
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
        return StoredKeychainClass(accessible: accessible, synchronizable: synchronizable)
    }

    /// A read's outcome, spelled alike for the copy and FernletFoundation's `KeychainItem`.
    private static func spelled(_ read: ProximityKeychainItem.ReadResult) -> String {
        switch read {
        case .found(let data): return "found \(hex(data))"
        case .absent: return "absent"
        case .unreadable(let status): return "unreadable \(status)"
        }
    }

    /// FernletFoundation's read outcome, spelled as the copy's is.
    private static func spelled(_ read: KeychainItem.ReadResult) -> String {
        switch read {
        case .found(let data): return "found \(hex(data))"
        case .absent: return "absent"
        case .unreadable(let status): return "unreadable \(status)"
        }
    }

    /// An enumeration's outcome, spelled alike for the copy and FernletFoundation's `KeychainItem`.
    private static func spelled(_ rows: ProximityKeychainItem.EnumerationResult) -> String {
        switch rows {
        case .rows(let rows): return "rows " + rows.map { "\($0.account)=\(hex($0.data))" }.joined(separator: ",")
        case .unreadable(let status): return "unreadable \(status)"
        }
    }

    /// FernletFoundation's enumeration outcome, spelled as the copy's is.
    private static func spelled(_ rows: KeychainItem.EnumerationResult) -> String {
        switch rows {
        case .rows(let rows): return "rows " + rows.map { "\($0.account)=\(hex($0.data))" }.joined(separator: ",")
        case .unreadable(let status): return "unreadable \(status)"
        }
    }

    // MARK: Helpers

    /// Compares every named row of `group` with its frozen literal, byte for byte, and returns how
    /// many it compared.
    @discardableResult
    private static func expectFrozen(_ group: NamespaceGoldenRow.Group) -> Int {
        var compared = 0
        // R2: bounded by the table.
        for row in table where row.group == group {
            guard let actual = row.todayBytes else { continue }
            compared += 1
            #expect(actual == Data(row.frozen.utf8), """
                \(row.field) moved: today it is "\(String(decoding: actual, as: UTF8.self))" \
                (\(hex(actual))), its frozen literal is "\(row.frozen)". Re-point the accessor; never \
                the literal.
                """)
        }
        return compared
    }

    /// The frozen literal of `field`, so a fixture spells a name the table pins instead of restating it.
    static func frozen(_ field: String) -> String {
        guard let row = table.first(where: { $0.field == field }) else {
            Issue.record("the golden table has no row \(field)")
            return ""
        }
        return row.frozen
    }

    /// Every `Logger(subsystem: "…"` literal in `source`, in order.
    private static func loggerSubsystems(in source: String) -> [String] {
        let opener = "Logger(subsystem: \""
        var found: [String] = []
        var rest = Substring(source)
        // R2: each pass consumes the opener it found, so the loop ends within the source's length.
        while let start = rest.range(of: opener) {
            let tail = rest[start.upperBound...]
            guard let close = tail.firstIndex(of: "\"") else { break }
            found.append(String(tail[..<close]))
            rest = tail[close...]
        }
        return found
    }

    /// The entries `directory` holds, by name, hidden ones aside and sorted.
    private static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The accounts of every row under `service`.
    private static func accounts(under service: String) -> Set<String> {
        Set(KeychainItem.loadAll(service: service).map { $0.account })
    }

    /// A fresh identity keychain service nobody else uses.
    private static func isolatedIdentityService() -> String {
        "com.fernlet.identity.test.namespacegolden.\(UUID().uuidString)"
    }

    /// A fresh scratch directory nobody else uses.
    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProximityNamespaceGolden-\(UUID().uuidString)", isDirectory: true)
    }

    /// An identity whose two private keys are planted at the frozen account names — signing `40…5f`,
    /// key agreement `60…7f` — and adopted by `ensureProvisioned()`'s first case. If the accounts
    /// moved, provisioning would mint fresh keys and nothing planted for the vectors would open.
    private static func plantedIdentity() throws -> (identity: IdentityService, service: String) {
        let service = isolatedIdentityService()
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let signing = KeychainItem.store(sequence(from: 0x40), account: frozen("installation.keychain.identity.signingPrivateKey"),
                                         service: service, accessibility: accessibility)
        let agreement = KeychainItem.store(sequence(from: 0x60),
                                           account: frozen("installation.keychain.identity.keyAgreementPrivateKey"),
                                           service: service, accessibility: accessibility)
        #expect(signing == errSecSuccess && agreement == errSecSuccess, "the planted identity rows did not land")
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        #expect(hex(identity.localKeyAgreementPublicKey) == plantedKeyAgreementPublicKeyHex,
                "provisioning did not adopt the planted key agreement key")
        return (identity, service)
    }

    /// Plants the column content key under `account` in `service`.
    private static func plantSealKey(account: String, service: String) {
        let status = KeychainItem.store(sequence(from: 0x00), account: account, service: service,
                                        accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(status == errSecSuccess, "the planted seal key did not land: \(status)")
    }

    /// Writes a hex vector to `name` inside `directory`.
    private static func writeBlob(_ blobHex: String, named name: String, in directory: URL) throws {
        let blob = try #require(bytes(hex: blobHex))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try blob.write(to: directory.appendingPathComponent(name, isDirectory: false))
    }

    /// A coordinator the manager only identity-compares against its slots. Never provisioned, so it
    /// writes no keychain row (the `MeshEncryptionTests` harness).
    private static func unprovisionedCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(namespace: .fernlet, keychainService: isolatedIdentityService()),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            replayCache: ReplayCache(),
            displayName: "Local",
            timeoutSeconds: 0)
    }

    /// Drives the real descriptor → grant join so the manager holds `groupKey` at `epoch`: the group
    /// key is private-set, so the join (which itself opens a production `FGK2` wrap) is the only way in.
    private static func join(_ manager: MeshNetworkManager, on coordinator: ProximityCoordinator,
                             admitter: IdentityService, groupKey: Data, epoch: Int) throws -> MeshDescriptor {
        let now = Date()
        let member = MeshMember(fingerprint: IdentityService.fingerprint(of: admitter.localSigningPublicKey),
                                displayName: "Admitter", signingPublicKey: admitter.localSigningPublicKey,
                                keyAgreementPublicKey: admitter.localKeyAgreementPublicKey, joinedAt: now)
        let mesh = MeshDescriptor(meshID: UUID(), name: "Before", mode: .open, members: [member],
                                  nameSetAt: now, nameSetBy: member.fingerprint,
                                  modeSetAt: now, modeSetBy: member.fingerprint, createdAt: now)
        try deliver(.meshDescriptor, MeshStateChangePayload(descriptor: mesh), to: manager, on: coordinator, from: nil)
        let token = try MeshAdmissionToken.signed(meshID: mesh.meshID, joinerFingerprint: manager.localFingerprint,
                                                  joinerSigningPublicKey: manager.localSigningPublicKey,
                                                  admitterIdentity: admitter)
        let grant = MeshAdmissionGrantPayload(
            meshID: mesh.meshID, requesterFingerprint: manager.localFingerprint, token: token,
            encryptedCurrentKey: try admitter.encryptGroupKey(groupKey, for: manager.localKeyAgreementPublicKey),
            currentKeyEpoch: epoch)
        try deliver(.meshAdmissionGrant, grant, to: manager, on: coordinator, from: peerIdentity(for: admitter))
        return mesh
    }

    /// `mesh` renamed `name`, its name stamped `secondsLater` after the original's.
    private static func renamed(_ mesh: MeshDescriptor, to name: String, secondsLater: TimeInterval) -> MeshDescriptor {
        var renamed = mesh
        renamed.name = name
        renamed.nameSetAt = mesh.nameSetAt.addingTimeInterval(secondsLater)
        return renamed
    }

    /// Seals `descriptor` as `FMGM2` ‖ AES-256-GCM(ciphertext ‖ tag) under the group key with `label`
    /// as the AAD — the marker and the label spelled from literals, never from production constants —
    /// and hands the wrapper to the manager's inbound door. The inner descriptor and the wrapper travel
    /// under the manager's namespace's mesh messages, as a peer of its family sends them.
    private static func deliverMetadata(_ descriptor: MeshDescriptor, label: String, groupKey: Data, nonce: Data,
                                        epoch: Int, to manager: MeshNetworkManager,
                                        on coordinator: ProximityCoordinator) throws {
        let inner = try JSONEncoder().encode(EncryptedMetadataInner(
            payloadType: manager.namespace.family.vocabulary.mesh.descriptor,
            payload: try JSONEncoder().encode(MeshStateChangePayload(descriptor: descriptor))))
        let box = try AES.GCM.seal(inner, using: SymmetricKey(data: groupKey), nonce: try AES.GCM.Nonce(data: nonce),
                                   authenticating: Data(label.utf8))
        let wrapper = MeshEncryptedMetadataPayload(ciphertext: Data("FMGM2".utf8) + box.ciphertext + box.tag,
                                                   nonce: nonce, keyEpoch: epoch)
        try deliver(.meshEncryptedMetadata, wrapper, to: manager, on: coordinator, from: nil)
    }

    /// Hands one already-verified envelope to the manager, as the coordinator does, under the manager's
    /// namespace's token for `role`: the token a peer of its family sends that frame under.
    private static func deliver<Payload: Encodable>(
        _ role: MeshPayloadRole, _ payload: Payload, to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator, from peer: ProximityCoordinator.PeerIdentity?
    ) throws {
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion, envelopeID: UUID(),
            senderSigningPublicKey: Data(), senderKeyAgreementPublicKey: Data(), senderDisplayName: "Peer",
            recipientFingerprint: nil, payloadTypeToken: role.token(in: manager.namespace.family.vocabulary.mesh),
            payloadEncryption: .none, payloadSummary: PayloadSummary(title: "Golden"), payload: plaintext,
            createdAt: Date(), expiresAt: nil, signature: Data())
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: peer)
    }

    /// The identity a grant is credited to.
    private static func peerIdentity(for identity: IdentityService) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "Admitter", signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: IdentityService.fingerprint(of: identity.localSigningPublicKey),
            rangingMode: .none, firstSeenAt: Date())
    }

    /// Polls until `condition` holds, giving up only after the deadline AND `minimumPolls` real looks,
    /// so a starved main actor cannot time out having barely looked (the `MeshEncryptionTests` rule).
    private static func waitUntil(timeout: Duration = .seconds(3), minimumPolls: Int = 400,
                                  _ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        // R2: ends once both the poll count and the deadline are reached; every pass sleeps.
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lowercase hex.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes from an even-length hex literal, or nil for anything else.
    static func bytes(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data()
        var index = hex.startIndex
        // R2: each pass consumes two characters of a finite literal.
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// `count` bytes counting up from `start` — the fixed key material every vector here is built on.
    static func sequence(from start: UInt8, count: Int = 32) -> Data {
        Data((0..<count).map { start &+ UInt8($0) })
    }

    /// `bytes` behind their 8-byte big-endian count, written here rather than by the production
    /// writer, so the twin cells frame a transcript independently of the code under test.
    static func lengthPrefixed(_ bytes: Data) -> Data {
        var framed = Data()
        let count = UInt64(bytes.count)
        // R2: eight iterations, one per byte of the count.
        for shift in stride(from: 56, through: 0, by: -8) {
            framed.append(UInt8(truncatingIfNeeded: count >> UInt64(shift)))
        }
        return framed + bytes
    }

    /// A UUID's 16 bytes in network order, read through its tuple.
    static func uuidBytes(_ uuid: UUID) -> Data {
        let raw = uuid.uuid
        return Data([raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
                     raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15])
    }

    /// A schema-v1 broadcast envelope from `sender`, carrying `signature`: the shape a pre-WI-6 peer
    /// still sends, signed over the legacy JSON bytes.
    private static func legacyEnvelope(sender: Data, signature: Data) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.legacySchemaVersion, envelopeID: MeshMembershipEventFixtures.proposalID,
            senderSigningPublicKey: sender, senderKeyAgreementPublicKey: Data(repeating: 0x02, count: 32),
            senderDisplayName: "Golden", recipientFingerprint: nil, payloadType: .inspectorEcho, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Golden"), payload: Data("golden legacy".utf8),
            createdAt: MeshMembershipEventFixtures.base, expiresAt: nil, signature: signature)
    }

    /// An admission token from `admitter` to `joiner` in the fixtures' mesh, carrying `signature`.
    private static func admissionToken(admitter: Data, joiner: Data, signature: Data) -> MeshAdmissionToken {
        MeshAdmissionToken(
            meshID: MeshMembershipEventFixtures.meshID, joinerFingerprint: IdentityService.fingerprint(of: joiner),
            joinerSigningPublicKey: joiner, admitterFingerprint: IdentityService.fingerprint(of: admitter),
            grantedAt: MeshMembershipEventFixtures.base, expiresAt: MeshMembershipEventFixtures.base.addingTimeInterval(3_600),
            admitterSigningPublicKey: admitter, admitterSignature: signature)
    }

    /// `token.verify(...in: purposes)` at the token's own grant instant, against the keys it was issued
    /// for: everything but the signature passes, so the signature is what the answer is about.
    private static func verifyToken(
        _ token: MeshAdmissionToken, keys: (admitter: Data, joiner: Data), in purposes: ProximityNamespace.Purposes
    ) throws {
        try token.verify(joinerSigningPublicKey: keys.joiner, expectedMeshID: token.meshID,
                         expectedAdmitterSigningPublicKey: keys.admitter, now: token.grantedAt, in: purposes)
    }

    /// `identity`'s admission to `meshID` by itself — a founder's record — signed by the production
    /// builder under the identity's own namespace.
    private static func selfAdmission(of identity: IdentityService, meshID: UUID) throws -> SignedAdmissionRecord {
        SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
            meshID: meshID, joinerFingerprint: identity.localFingerprint,
            joinerSigningPublicKey: identity.localSigningPublicKey, admitterIdentity: identity))
    }

    /// The refusal a ledger step answered, or nil when it adopted.
    private static func refusal(_ outcome: MeshLedgerAdoptionOutcome) -> MeshLedgerAdoptionRefusal? {
        guard case .refused(let refusal) = outcome else { return nil }
        return refusal
    }

    /// The fixture verify response (scanner key `44…`, challenge nonce `55…`, QR nonce `66…`), framed
    /// by `purposes`.
    private static func verifyResponse(in purposes: ProximityNamespace.Purposes) -> Data {
        ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: Data(repeating: 0x44, count: 32),
            challengeNonce: Data(repeating: 0x55, count: 16), qrNonce: Data(repeating: 0x66, count: 16), in: purposes)
    }

    /// The fixture channel introduction the group-3 and group-6 cells frame.
    private static func introductionTranscript() -> MeshChannelIntroductionTranscript {
        MeshChannelIntroductionTranscript(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion, meshID: MeshMembershipEventFixtures.meshID,
            epochRef: "7", initiatorSigningPublicKey: Data(repeating: 0x06, count: 32),
            responderSigningPublicKey: Data(repeating: 0x07, count: 32), initiatorNonce: Data(repeating: 0x08, count: 16),
            responderNonce: Data(repeating: 0x09, count: 16), channelBindingHash: Data(repeating: 0x0A, count: 32))
    }

    /// A ledger admitting `signingKey`, by its fingerprint, to the fixtures' mesh. The routed doors
    /// resolve a signer's key from the admissions and verify no admission themselves, so the token's
    /// own signature is the fixtures' opaque one.
    private static func ledgerAdmitting(_ signingKey: Data) -> MeshMembershipLedger {
        var ledger = MeshMembershipLedger.empty
        ledger.admissions = ledger.admissions.inserting(SignedAdmissionRecord(token: admissionToken(
            admitter: signingKey, joiner: signingKey, signature: MeshMembershipEventFixtures.opaqueSignature)))
        return ledger
    }

    /// Each routed door's answer to its golden fixture record, re-addressed to `key`'s fingerprint and
    /// signed by `key` over the bytes `signer` frames for it, at a door holding `checker`: the
    /// rejection's frozen token, or `accepted`. The receipt and chunk doors hold no manifest, so only
    /// the checks every record owes run. Since step A0.2.6 the chunk's own hash is taken in `signer`
    /// too: a chunk door re-derives it under the labels it holds, so a chunk made in a namespace
    /// carries that namespace's hash.
    private static func routedVerdicts(
        signedBy key: Curve25519.Signing.PrivateKey, in signer: ProximityNamespace.Purposes,
        checkedIn checker: ProximityNamespace.Purposes
    ) throws -> [String: String] {
        let me = IdentityService.fingerprint(of: key.publicKey.rawRepresentation)
        let ledger = ledgerAdmitting(key.publicKey.rawRepresentation)
        let (meshID, deadline) = (MeshRoutedManifestFixtures.meshID, MeshRoutedManifestFixtures.hardDeadline)
        let manifest = MeshRoutedManifestFixtures.manifest().replacing(originFingerprint: me)
        let chunk = MeshChunkFixtures.chunk().replacing(
            originFingerprint: me, chunkHash: MeshRoutedContentDigest.chunkHash(of: MeshChunkFixtures.payload, in: signer))
        let custody = MeshCustodyReceiptFixtures.receipt().replacing(custodianFingerprint: me)
        let recipient = MeshRecipientReceiptFixtures.receipt().replacing(recipientFingerprint: me)
        let inventory = MeshRoutedInventoryFixtures.payload().replacing(senderFingerprint: me)
        let answer = MeshRoutedDrainAnswerFixtures.payload().replacing(senderFingerprint: me)
        let verdicts: [String: String?] = [
            "manifest": MeshRoutedManifestVerifier(
                meshID: meshID, hardDeadline: deadline, ledger: ledger,
                acceptedTypeTokens: MeshRoutedManifestFixtures.acceptedTypeTokens, purposes: checker
            ).verify(manifest.replacing(signature: try key.signature(for: canonicalBytes(for: manifest, in: signer))))?.rawValue,
            "chunk": MeshChunkVerifier(
                meshID: meshID, hardDeadline: deadline, ledger: ledger, manifest: nil, purposes: checker
            ).verify(chunk.replacing(signature: try key.signature(for: canonicalBytes(for: chunk, in: signer))))?.rawValue,
            "custodyReceipt": MeshCustodyReceiptVerifier(
                meshID: meshID, hardDeadline: deadline, ledger: ledger, manifest: nil, purposes: checker
            ).verify(custody.replacing(signature: try key.signature(for: canonicalBytes(for: custody, in: signer))))?.rawValue,
            "recipientReceipt": MeshRecipientReceiptVerifier(
                meshID: meshID, hardDeadline: deadline, ledger: ledger, manifest: nil, purposes: checker
            ).verify(recipient.replacing(signature: try key.signature(for: canonicalBytes(for: recipient, in: signer))))?.rawValue,
            "routedInventory": MeshRoutedInventoryVerifier(meshID: meshID, ledger: ledger, purposes: checker)
                .verify(inventory.replacing(signature: try key.signature(for: canonicalBytes(for: inventory, in: signer))))?.rawValue,
            "drainAnswer": MeshRoutedDrainAnswerVerifier(meshID: meshID, ledger: ledger, purposes: checker)
                .verify(answer.replacing(signature: try key.signature(for: canonicalBytes(for: answer, in: signer))))?.rawValue
        ]
        return verdicts.mapValues { $0 ?? "accepted" }
    }

    /// A responder holding `purposes` takes `initiator`'s hello and reviews `signed` over the
    /// transcript it binds.
    private static func review(
        _ signed: MeshChannelIntroduction, from initiator: MeshIntroductionHarness.Endpoint,
        by responder: MeshIntroductionHarness.Endpoint, in purposes: ProximityNamespace.Purposes
    ) -> MeshChannelIntroductionOutcome {
        var exchange = MeshChannelIntroductionExchange(role: .responder, localHello: responder.hello, purposes: purposes)
        var nonces = MeshIntroductionNonceCache()
        #expect(exchange.receive(initiator.hello, roster: MeshIntroductionHarness.roster(initiator, responder),
                                 nonces: &nonces) == nil)
        let bound = exchange.bind(channelBindingHash: MeshIntroductionHarness.binding)
        #expect(bound != nil, "a responder holding \(purposes.signature.meshChannelIntroductionV1.rawValue) bound nothing")
        return exchange.review(signed)
    }

    /// The seven routed digest and id readers' answers under `purposes`, keyed by reader, each expected
    /// to be SHA-256 over that namespace's field prefix then the reader's own tail (written with the
    /// production writer, as group 6's cells write it).
    private static func routedDigests(in purposes: ProximityNamespace.Purposes) -> [String: Data] {
        let hash = purposes.hash
        let blob = Data("golden routed blob".utf8)
        let (chunk, custody, recipient) = (MeshChunkFixtures.chunk(), MeshCustodyReceiptFixtures.receipt(),
                                           MeshRecipientReceiptFixtures.receipt())
        var streamed = MeshRoutedContentHasher(purposes: purposes)
        streamed.update(blob.prefix(7))
        streamed.update(blob.dropFirst(7))
        let chunkTail = chunkIDTail(itemID: chunk.itemID, index: chunk.chunkIndex)
        let answers: [(reader: String, value: Data, field: ProximityCryptographicPurpose, tail: Data)] = [
            ("contentHash(of:in:)", MeshRoutedContentDigest.contentHash(of: blob, in: purposes), hash.meshRoutedContentV1, blob),
            ("MeshRoutedContentHasher(purposes:)", streamed.finalized(), hash.meshRoutedContentV1, blob),
            ("chunkHash(of:in:)", MeshRoutedContentDigest.chunkHash(of: chunk.payload, in: purposes), hash.meshRoutedChunkV1,
             chunk.payload),
            ("chunkID(itemID:chunkIndex:in:)",
             uuidBytes(MeshRoutedContentDigest.chunkID(itemID: chunk.itemID, chunkIndex: chunk.chunkIndex, in: purposes)),
             hash.meshRoutedChunkIDV1, chunkTail),
            ("MeshChunk.chunkID(in:)", uuidBytes(chunk.chunkID(in: purposes)), hash.meshRoutedChunkIDV1, chunkTail),
            ("MeshCustodyReceipt.receiptID(in:)", uuidBytes(custody.receiptID(in: purposes)), hash.meshCustodyReceiptIDV1,
             receiptIDTail(itemID: custody.itemID, origin: custody.originFingerprint, signer: custody.custodianFingerprint)),
            ("MeshRecipientReceipt.receiptID(in:)", uuidBytes(recipient.receiptID(in: purposes)), hash.meshRecipientReceiptIDV1,
             receiptIDTail(itemID: recipient.itemID, origin: recipient.originFingerprint, signer: recipient.recipientFingerprint))
        ]
        // R2: bounded by the seven readers.
        for answer in answers {
            expectDigest(answer.value, over: answer.tail, by: answer.field, consumer: "\(answer.reader) under \(answer.field.rawValue)")
        }
        return Dictionary(answers.map { ($0.reader, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// A chunk id's tail after its domain: the item's UUID, then the index as a `u64`.
    private static func chunkIDTail(itemID: UUID, index: UInt32) -> Data {
        var tail = CanonicalByteWriter()
        tail.appendUUID(itemID)
        tail.appendUInt64(UInt64(index))
        return tail.bytes
    }

    /// A receipt id's tail after its domain: the item's UUID, then the origin and the signer, each
    /// length-prefixed.
    private static func receiptIDTail(itemID: UUID, origin: String, signer: String) -> Data {
        var tail = CanonicalByteWriter()
        tail.appendUUID(itemID)
        tail.appendString(origin)
        tail.appendString(signer)
        return tail.bytes
    }

    /// An epoch id's tail after its raw domain: the lowercase mesh id, the counter as four big-endian
    /// bytes and the coordinator's fingerprint — written here, not by the production derivation.
    static func epochTail(meshID: UUID, counter: UInt32, coordinator: String) -> Data {
        var tail = Data(meshID.uuidString.lowercased().utf8)
        // R2: four iterations, one per byte of the counter.
        for shift in stride(from: 24, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: counter >> UInt32(shift)))
        }
        return tail + Data(coordinator.utf8)
    }

    /// Fernlet's labels with the named groups taken from another app's instead, so a cell can move
    /// exactly one family of reads while every other read — the signatures above all — stays Fernlet's.
    private static func fernletPurposes(
        keyDerivation: ProximityNamespace.KeyDerivation = .fernlet,
        aead: ProximityNamespace.AEAD = .fernlet,
        hash: ProximityNamespace.Hash = .fernlet
    ) -> ProximityNamespace.Purposes {
        ProximityNamespace.Purposes(signature: .fernlet, keyDerivation: keyDerivation, aead: aead, hash: hash)
    }

    /// Fernlet's labels, then a variant whose key-derivation group and one whose AEAD group is the
    /// foreign app's: any two of the three differ in the salts, the AEAD labels or both.
    private static func saltAndAEADVariants() -> [(name: String, purposes: ProximityNamespace.Purposes)] {
        [("Fernlet's labels", .fernlet),
         ("another app's salts", fernletPurposes(keyDerivation: ForeignAppNamespace.keyDerivation())),
         ("another app's AEAD labels", fernletPurposes(aead: ForeignAppNamespace.aead()))]
    }

    /// `.fernlet` with its labels replaced by `purposes`: the namespace an identity of a variant is
    /// built from.
    private static func fernletNamespace(with purposes: ProximityNamespace.Purposes) -> ProximityNamespace {
        ProximityNamespace(
            family: ProximityNamespace.Family(purposes: purposes, radios: .fernlet,
                                              verifyQR: ProximityNamespace.fernlet.family.verifyQR,
                                              vocabulary: .fernlet),
            installation: .fernletApp)
    }

    /// The fixture payload as the only chunk of its item (index 0 of 1, so a parked reassembler takes
    /// its four bytes), addressed from `key`'s fingerprint, its payload hashed in `purposes` and its
    /// transcript signed by `key` under `purposes`' chunk signature label.
    private static func signedChunk(
        by key: Curve25519.Signing.PrivateKey, hashedIn purposes: ProximityNamespace.Purposes
    ) throws -> MeshChunk {
        let base = MeshChunkFixtures.chunk(index: 0, count: 1, payload: MeshChunkFixtures.payload)
        let unsigned = base.replacing(originFingerprint: IdentityService.fingerprint(of: key.publicKey.rawRepresentation),
                                      chunkHash: MeshRoutedContentDigest.chunkHash(of: base.payload, in: purposes))
        return unsigned.replacing(signature: try key.signature(for: canonicalBytes(for: unsigned, in: purposes)))
    }

    /// A manifest-less chunk door holding `purposes`, over a ledger admitting `key`: its verdict on
    /// `chunk`, or nil when it accepts it.
    private static func chunkVerdict(
        _ chunk: MeshChunk, signedBy key: Curve25519.Signing.PrivateKey, heldIn purposes: ProximityNamespace.Purposes
    ) -> MeshChunkRejection? {
        MeshChunkVerifier(meshID: MeshRoutedManifestFixtures.meshID, hardDeadline: MeshRoutedManifestFixtures.hardDeadline,
                          ledger: ledgerAdmitting(key.publicKey.rawRepresentation), manifest: nil, purposes: purposes)
            .verify(chunk)
    }

    /// A one-chunk item hashed in `purposes`: a 1 000-byte blob, its chunk (index 0 of 1) and an
    /// unsigned manifest for it. The reassembler verifies no signature: an accepted manifest and chunk
    /// are its callers' precondition.
    private static func singleChunkItem(
        hashedIn purposes: ProximityNamespace.Purposes
    ) -> (blob: Data, chunk: MeshChunk, manifest: MeshRoutedManifest) {
        let blob = MeshChunkFixtures.blob(byteCount: 1_000)
        let contentHash = MeshRoutedContentDigest.contentHash(of: blob, in: purposes)
        let chunk = MeshChunkFixtures.chunk(index: 0, count: 1, payload: blob, contentHash: contentHash)
            .replacing(chunkHash: MeshRoutedContentDigest.chunkHash(of: blob, in: purposes))
        let manifest = MeshRoutedManifestFixtures.manifest().replacing(
            itemID: chunk.itemID, originFingerprint: chunk.originFingerprint, contentHash: contentHash,
            size: UInt64(blob.count))
        return (blob, chunk, manifest)
    }

    /// On a fresh isolated routed store under a pinned install binding: admits `manifest`, then stages
    /// `chunk`, commits custody of the item and reads its blob back, each first through a store whose
    /// scope carries `other`'s labels — which must refuse — and then through one whose scope carries
    /// `family`'s, the labels the item was hashed in. Both scopes keep Fernlet's installation, the
    /// fixture's directory, its keychain service and its install binding, and both take `family`'s
    /// key-derivation group, whose column seal the stores seal the index under since step A0.2.9, so
    /// the two stores open one index under one key and one column seal and differ in the labels they
    /// measure under alone. The store verifies no signature: an accepted manifest and chunk are its
    /// callers' precondition.
    private static func expectStoreMeasures(
        _ chunk: MeshChunk, of blob: Data, manifest: MeshRoutedManifest,
        hashedIn family: ProximityNamespace.Family, notIn other: ProximityNamespace.Family
    ) {
        let scope = MeshRoutedStoreFixtures.scope()
        defer { MeshRoutedStoreFixtures.tearDown(scope) }
        func store(_ labels: ProximityNamespace.Family) -> MeshRoutedStore {
            let purposes = ProximityNamespace.Purposes(
                signature: labels.purposes.signature, keyDerivation: family.purposes.keyDerivation,
                aead: labels.purposes.aead, hash: labels.purposes.hash)
            let sealedAlike = ProximityNamespace.Family(purposes: purposes, radios: labels.radios, verifyQR: labels.verifyQR,
                                                        vocabulary: labels.vocabulary)
            return MeshRoutedStore(scope: MeshRoutedStorageScope(
                namespace: ProximityNamespace(family: sealedAlike, installation: scope.namespace.installation),
                directory: scope.directory, keychainService: scope.keychainService, installBinding: scope.installBinding))
        }
        let (hashed, unhashed) = (store(family), store(other))
        let (key, now, custodian) = (MeshRoutedItemKey(manifest), MeshRoutedStoreFixtures.now, "fp-golden-custodian")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshRoutedStoreFixtures.installA)) {
            #expect(hashed.admittingManifest(manifest, now: now).value != nil, "the store refused the item's manifest")
            #expect(unhashed.stagingChunk(chunk, now: now) == .completed(.refused(.chunkHashMismatch)))
            #expect(hashed.stagingChunk(chunk, now: now) == .completed(.admitted(received: 1, expected: 1)))
            #expect(unhashed.committingCustody(item: key, custodian: custodian, now: now)
                        == .completed(.refused(.contentHashMismatch)))
            let committed = hashed.committingCustody(item: key, custodian: custodian, now: now)
            guard case .completed(.committed(let witness)) = committed else {
                Issue.record("the store did not commit custody under the item's own labels: \(committed)")
                return
            }
            #expect(witness.contentHash == manifest.contentHash)
            #expect(unhashed.assembledBlob(item: key, expecting: manifest) == .completed(nil))
            #expect(hashed.assembledBlob(item: key, expecting: manifest) == .completed(blob))
        }
    }

    /// Whether a door opened to `expected` (`true`) or refused with exactly `refusal` (`false`). Any
    /// other answer — other bytes, another error — is neither, so a cell comparing it fails.
    private static func opened<Refusal: Error & Equatable>(
        _ answer: Result<Data, any Error>, expecting expected: Data, refusal: Refusal
    ) -> Bool? {
        switch answer {
        case .success(let bytes): return bytes == expected ? true : nil
        case .failure(let error): return (error as? Refusal) == refusal ? false : nil
        }
    }

    /// Whether `role` is a signature role, of any framing.
    static func isSignatureRole(_ role: ProximityCryptographicPurpose.Role) -> Bool {
        guard case .signature = role else { return false }
        return true
    }

    /// Whether a new transcript may be signed under `role`, as the design puts it: a length-prefixed
    /// or raw-prefix signature, never the verify-only `.absent`. Spelled here independently of the
    /// production check it is compared with.
    static func isWritableSignatureRole(_ role: ProximityCryptographicPurpose.Role) -> Bool {
        role == .signature(.lengthPrefixed) || role == .signature(.rawPrefix)
    }
}

// MARK: - A host of another app's namespace

/// A `ProximityHost` that supplies a namespace other than Fernlet's, on a scratch sidecar root and
/// seal-key services of its own: the one host here that a manager can be built over and read nothing
/// of `.fernlet` from (plan step A0.2.6's metadata cell).
@MainActor
private final class ForeignNamespaceHost: ProximityHost {
    let proximityNamespace: ProximityNamespace
    let proximityInstallBinding: any ProximityInstallBinding = FernletDeviceBindingAdapter()
    let proximitySupportDirectory: URL
    let meshSessionStorage: MeshSessionStorageScope
    let meshRoutedStorage: MeshRoutedStorageScope
    let proximityTrustVault = ProximityTrustVault()
    var proximityTrustStore: any ProximityTrustStore { proximityTrustVault }
    var proximityDisplayName: String { "Golden" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }

    /// A host of `namespace` on a fresh scratch root and fresh `.test.` seal-key services.
    init(namespace: ProximityNamespace) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProximityNamespaceGoldenHost-\(UUID().uuidString)", isDirectory: true)
        proximityNamespace = namespace
        proximitySupportDirectory = root
        meshSessionStorage = MeshSessionStorageScope(
            namespace: namespace, directory: root,
            keychainService: "com.fernlet.mesh-session.test.namespacegolden.\(UUID().uuidString)",
            installBinding: FernletDeviceBindingAdapter())
        meshRoutedStorage = MeshRoutedStorageScope(
            namespace: namespace, directory: root,
            keychainService: "com.fernlet.mesh-routed.test.namespacegolden.\(UUID().uuidString)",
            installBinding: FernletDeviceBindingAdapter())
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool { proximityTrustVault.isBlockedFingerprint(fingerprint) }
    func blockProximityPeer(signingPublicKey: Data) { proximityTrustVault.block(signingPublicKey: signingPublicKey) }
    func makeProximityTrustPolicy() -> any ProximityTrustPolicy { FriendSessionTrustPolicy(vault: proximityTrustVault) }

    /// Removes the scratch root and both seal-key rows.
    func tearDown() {
        MeshSessionStore.wipeForDeleteAll(scope: meshSessionStorage)
        MeshRoutedStore.wipeForDeleteAll(scope: meshRoutedStorage)
        try? FileManager.default.removeItem(at: proximitySupportDirectory)
    }
}

// MARK: - Hosts of the extension defaults

/// A `ProximityHost` that supplies only its namespace and the requirements with no default, so its
/// sidecar root and both storage scopes are `ProximityHost`'s extension defaults, built from that
/// namespace (plan step A0.2.8's cell) and its install binding (plan step A0.2.9). Building one
/// touches no disk and no keychain.
@MainActor
private final class NamespaceDefaultsHost: ProximityHost {
    let proximityNamespace: ProximityNamespace
    let proximityInstallBinding: any ProximityInstallBinding
    let proximityTrustVault = ProximityTrustVault()
    var proximityTrustStore: any ProximityTrustStore { proximityTrustVault }
    var proximityDisplayName: String { "Golden" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }

    /// A host of `namespace` on the extension's default root, supplying `installBinding` (Fernlet's
    /// adapter unless a cell hands it one of its own).
    init(namespace: ProximityNamespace, installBinding: any ProximityInstallBinding = FernletDeviceBindingAdapter()) {
        proximityNamespace = namespace
        proximityInstallBinding = installBinding
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool { proximityTrustVault.isBlockedFingerprint(fingerprint) }
    func blockProximityPeer(signingPublicKey: Data) { proximityTrustVault.block(signingPublicKey: signingPublicKey) }
    func makeProximityTrustPolicy() -> any ProximityTrustPolicy { FriendSessionTrustPolicy(vault: proximityTrustVault) }
}

/// ``NamespaceDefaultsHost`` on a sidecar root of its own: only its two storage scopes are the
/// extension defaults.
@MainActor
private final class RootedNamespaceDefaultsHost: ProximityHost {
    let proximityNamespace: ProximityNamespace
    let proximityInstallBinding: any ProximityInstallBinding
    let proximitySupportDirectory: URL
    let proximityTrustVault = ProximityTrustVault()
    var proximityTrustStore: any ProximityTrustStore { proximityTrustVault }
    var proximityDisplayName: String { "Golden" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }

    /// A host of `namespace` on `root`, supplying `installBinding` (Fernlet's adapter unless a cell
    /// hands it one of its own).
    init(
        namespace: ProximityNamespace, root: URL,
        installBinding: any ProximityInstallBinding = FernletDeviceBindingAdapter()
    ) {
        proximityNamespace = namespace
        proximitySupportDirectory = root
        proximityInstallBinding = installBinding
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool { proximityTrustVault.isBlockedFingerprint(fingerprint) }
    func blockProximityPeer(signingPublicKey: Data) { proximityTrustVault.block(signingPublicKey: signingPublicKey) }
    func makeProximityTrustPolicy() -> any ProximityTrustPolicy { FriendSessionTrustPolicy(vault: proximityTrustVault) }
}

// MARK: - An install binding of the test's own

/// An install binding that answers the same bytes to every read and never consults `DeviceBindingID`,
/// so a cell can tell the binding a scope hands a store from the one Fernlet's adapter would read
/// (plan step A0.2.9's cells).
private struct PinnedInstallBinding: ProximityInstallBinding {
    /// The bytes every read answers.
    let bytes: Data

    /// `bytes`, whatever the access.
    func read(for access: ProximityInstallBindingAccess) throws(ProximityInstallBindingReadError) -> Data? {
        bytes
    }
}

// MARK: - A foreign app

/// An app that does not exist, "acme", its namespace built entirely from its own literals: the shape a
/// non-Fernlet host of ProximityKit supplies (plan step A1.2's example app is the real one). It has no
/// legacy peers, so its legacy pair is `.refused`, and it shares nothing with Fernlet on purpose: no
/// label, radio value or name, and no token, title or presentation string either.
private enum ForeignAppNamespace {

    /// The namespace: sound, and disjoint from `.fernlet` everywhere.
    static func namespace() -> ProximityNamespace {
        ProximityNamespace(
            family: ProximityNamespace.Family(
                purposes: ProximityNamespace.Purposes(signature: signature(), keyDerivation: keyDerivation(),
                                                      aead: aead(), hash: hash()),
                radios: ProximityNamespace.Radios(
                    mesh: ProximityNamespace.Radio(serviceType: "_acme-mesh._udp", alpn: "acme-mesh-v1"),
                    presence: ProximityNamespace.Radio(serviceType: "_acme-near._udp", alpn: "acme-near-v1"),
                    recipeShare: ProximityNamespace.Radio(serviceType: "_acme-recipe._udp", alpn: "acme-recipe-v1"),
                    meshHeartbeat: Data("acme-mesh-heartbeat".utf8),
                    meshInstanceNamePrefix: "acme-link-", presenceInstanceNamePrefix: "ac-",
                    tlsCommonName: "acme-link"),
                verifyQR: ProximityNamespace.VerifyQR(urlScheme: "acme"),
                vocabulary: vocabulary()),
            installation: ProximityNamespace.Installation(
                keychain: ProximityNamespace.Keychain(
                    identity: ProximityNamespace.Keychain.IdentityRows(
                        service: "org.example.acme.identity", signingPrivateKey: "signing.private",
                        keyAgreementPrivateKey: "agreement.private", signingPublicKeyCache: "signing.public",
                        keyAgreementPublicKeyCache: "agreement.public"),
                    meshSessionSealKey: ProximityNamespace.Keychain.Row(service: "org.example.acme.mesh-session",
                                                                        account: "session.seal"),
                    meshRoutedSealKey: ProximityNamespace.Keychain.Row(service: "org.example.acme.mesh-routed",
                                                                       account: "routed.seal")),
                storage: ProximityNamespace.Storage(
                    directoryName: "Acme", meshSessionContextFileName: "Session.sealed",
                    meshRoutedIndexFileName: "Routed.sealed", meshRoutedChunkDirectoryName: "RoutedChunks"),
                logSubsystem: "org.example.acme",
                peerNames: ProximityNamespace.PeerNames(maxLength: 30, floor: "An acme pal")))
    }

    /// Nineteen signature labels and no legacy pair.
    static func signature() -> ProximityNamespace.Signature {
        ProximityNamespace.Signature(
            identityEnvelopeV2: "acme.canonical.identity-envelope.v2",
            meshAdmissionTokenV2: "acme.canonical.mesh-admission-token.v2",
            meshChannelIntroductionV1: "acme.mesh.channel-introduction.v1",
            meshMemberDepartureV1: "acme.mesh.member-departure.v1",
            meshMemberRemovalV1: "acme.mesh.member-removal.v1",
            meshTerminatedV1: "acme.mesh.terminated.v1",
            meshInventoryDigestV1: "acme.mesh.inventory-digest.v1",
            meshEpochHeadsV1: "acme.mesh.epoch-heads.v1",
            meshRemovalProposalV1: "acme.mesh.removal-proposal.v1",
            meshRemovalVoteV1: "acme.mesh.removal-vote.v1",
            meshKeyAgreementV1: "acme.mesh.key-agreement.v1",
            meshRoutedManifestV1: "acme.mesh.routed-manifest.v1",
            meshRoutedChunkV1: "acme.mesh.routed-chunk.v1",
            meshCustodyReceiptV1: "acme.mesh.custody-receipt.v1",
            meshRecipientReceiptV1: "acme.mesh.recipient-receipt.v1",
            meshRoutedInventoryDigestV1: "acme.mesh.routed-inventory-digest.v1",
            meshRoutedDrainAnswerV1: "acme.mesh.routed-drain-answer.v1",
            proximityQRIdentityV1: "acme.verify.qr.v1",
            proximityQRResponseV1: "acme.verify.response.v1",
            legacyV1: .refused
        )
    }

    /// The six key-derivation labels.
    static func keyDerivation() -> ProximityNamespace.KeyDerivation {
        ProximityNamespace.KeyDerivation(
            proximityTransportV1: "acme.proximity.v1",
            meshGroupKeyWrapV1: "acme.mesh.groupkey.v1",
            meshTLSExporterV1: "acme.mesh.tls-exporter.v1",
            meshRoutedContentKeyWrapV1: "acme.mesh.routed.content-key.v1",
            meshSessionContextV1: "acme.mesh.session-context.v1",
            meshRoutedStoreV1: "acme.mesh.routed-store.v1"
        )
    }

    /// The five AEAD labels.
    static func aead() -> ProximityNamespace.AEAD {
        ProximityNamespace.AEAD(
            proximityTransportV2: "acme.proximity.transport.aead.v2",
            meshGroupKeyWrapV2: "acme.mesh.groupkey.wrap.aead.v2",
            meshEncryptedMetadataV2: "acme.mesh.encrypted-metadata.aead.v2",
            meshRoutedContentKeyWrapV1: "acme.mesh.routed.content-key.wrap.aead.v1",
            meshRoutedItemV1: "acme.mesh.routed.item.aead.v1"
        )
    }

    /// The seven hash labels.
    static func hash() -> ProximityNamespace.Hash {
        ProximityNamespace.Hash(
            meshInventoryDigestV1: "acme.mesh.inventory-digest.hash.v1",
            meshRoutedContentV1: "acme.mesh.routed-content.hash.v1",
            meshRoutedChunkV1: "acme.mesh.routed-chunk.hash.v1",
            meshRoutedChunkIDV1: "acme.mesh.routed-chunk-id.hash.v1",
            meshCustodyReceiptIDV1: "acme.mesh.custody-receipt-id.hash.v1",
            meshRecipientReceiptIDV1: "acme.mesh.recipient-receipt-id.hash.v1",
            meshEpochIDV1: "acme.mesh.epoch.v1"
        )
    }

    /// Its payload vocabulary: its own session messages and titles, five payload tokens of which two
    /// must arrive sealed and its thirty mesh messages, three capabilities with no legacy peers to
    /// assume anything for, and its own record kinds and routed types.
    static func vocabulary() -> ProximityNamespace.Vocabulary {
        let meshToken = { (name: String) in "acme.mesh.\(name).v1" }
        return ProximityNamespace.Vocabulary(
            session: ProximityNamespace.SessionMessages(
                identityIntroduction: ProximityNamespace.SessionMessage(payloadType: "acme.hello.v1", summaryTitle: "Hi"),
                identityAcknowledge: ProximityNamespace.SessionMessage(payloadType: "acme.welcome.v1",
                                                                       summaryTitle: "Welcome"),
                heartbeat: ProximityNamespace.Heartbeat(payloadType: "acme.beat.v1", pingTitle: "Ping",
                                                        replyTitle: "Pong")),
            payloads: ProximityNamespace.PayloadRules(
                known: Set(["acme.hello.v1", "acme.welcome.v1", "acme.beat.v1", "acme.note.v1", "acme.sketch.v1"]
                           + ProximityNamespace.MeshMessages.tokens(meshToken)),
                sealingRequired: ["acme.note.v1", "acme.sketch.v1"]),
            capabilities: ProximityNamespace.Capabilities(
                known: ["notes", "sketches", "framing"], wire2: "framing", assumedForLegacyPeers: []),
            membershipRecordKinds: ProximityNamespace.MembershipRecordKinds(
                admission: "acme.member.joined.v1", departure: "acme.member.left.v1",
                removal: "acme.member.removed.v1", termination: "acme.group.ended.v1"),
            routedTypes: ProximityNamespace.RoutedTypes(
                photo: "acme.routed.picture.v1", tempMessage: "acme.routed.note.v1",
                heart: "acme.routed.wave.v1", control: "acme.routed.control.v1"),
            mesh: .spelled(meshToken)
        )
    }
}

// MARK: - FernletFoundation's keychain queries, read out of its source

/// FernletFoundation's `KeychainItem` query dictionaries, read out of `KeychainHelpers.swift` and
/// evaluated for one call, so group 15 holds ProximityKit's copy to the dictionaries FernletFoundation
/// issues rather than to a transcription of them (plan step A0.2.11).
///
/// A member's dictionary is the first `let query: [String: Any] = [ … ]` literal after its first
/// declaration (the string-keyed one; the `Account`-typed overloads come later and spell no dictionary
/// of their own), provided no other declaration starts between the two. Each `key as String: value`
/// entry is resolved through the tables below: a Security constant, a Boolean literal, the scope's
/// `queryValue` arm (read out of the same source) or one of the call's arguments. A token the tables
/// do not know leaves the member with no dictionary at all, so a key FernletFoundation adds fails the
/// comparison instead of dropping out of it.
private struct FernletFoundationKeychainQueries {

    /// The members whose dictionaries ProximityKit's copy reproduces.
    static let members = ["store", "load", "loadDistinguishingAbsence", "loadAllDistinguishingFailure",
                          "deleteReportingStatus", "deleteAllReportingStatus"]

    /// Each member's `key as String: value` entries, as source tokens in source order.
    private let entries: [String: [(key: String, value: String)]]
    /// `SynchronizableScope.queryValue`'s arms: the value token each case returns, by case name.
    private let scopeArms: [String: String]

    /// Reads every member's dictionary, and the scope arms, out of `source`.
    ///
    /// - Parameter source: The text of `FernletKit/Sources/FernletFoundation/KeychainHelpers.swift`.
    init(source: String) {
        let lines = source.components(separatedBy: "\n")
        var entries: [String: [(key: String, value: String)]] = [:]
        // R2: bounded by the six members.
        for member in Self.members {
            entries[member] = Self.queryEntries(of: member, in: lines)
        }
        self.entries = entries
        self.scopeArms = Self.scopeArms(in: lines)
    }

    /// The dictionary `member` issues for `call`: its `service`, `account`, `data`, `accessibility` and
    /// `synchronizable` arguments and, for a scoped member, `scope` (`any`, `synced` or `local`). Nil
    /// when the member's literal was not found or spells a token the evaluation does not know.
    func query(_ member: String, _ call: [String: Any]) -> [String: Any]? {
        guard let spelled = entries[member], !spelled.isEmpty else { return nil }
        var query: [String: Any] = [:]
        // R2: bounded by the member's entries.
        for entry in spelled {
            guard let key = Self.key(entry.key), let resolved = self.value(of: entry.value, in: call),
                  query[key] == nil else { return nil }
            query[key] = resolved
        }
        return query
    }

    /// The value a source token stands for in `call`.
    private func value(of token: String, in call: [String: Any]) -> Any? {
        guard token == "synchronizable.queryValue" else { return Self.constant(token) ?? call[token] }
        guard let scope = call["scope"] as? String, let arm = scopeArms[scope] else { return nil }
        return Self.constant(arm)
    }

    /// The query key a source token names, or nil for one the evaluation does not know.
    private static func key(_ token: String) -> String? {
        switch token {
        case "kSecClass": return kSecClass as String
        case "kSecAttrService": return kSecAttrService as String
        case "kSecAttrAccount": return kSecAttrAccount as String
        case "kSecAttrAccessible": return kSecAttrAccessible as String
        case "kSecAttrSynchronizable": return kSecAttrSynchronizable as String
        case "kSecMatchLimit": return kSecMatchLimit as String
        case "kSecReturnData": return kSecReturnData as String
        case "kSecReturnAttributes": return kSecReturnAttributes as String
        case "kSecValueData": return kSecValueData as String
        case "kSecUseDataProtectionKeychain": return kSecUseDataProtectionKeychain as String
        default: return nil
        }
    }

    /// The constant a source token names, or nil for an argument or an unknown token.
    private static func constant(_ token: String) -> Any? {
        switch token {
        case "kSecClassGenericPassword": return kSecClassGenericPassword
        case "kSecMatchLimitOne": return kSecMatchLimitOne
        case "kSecMatchLimitAll": return kSecMatchLimitAll
        case "kSecAttrSynchronizableAny": return kSecAttrSynchronizableAny
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// The `key as String: value` entries of `member`'s dictionary literal, or [] when the literal is
    /// not where the reading expects it or holds a line of another shape.
    private static func queryEntries(of member: String, in lines: [String]) -> [(key: String, value: String)] {
        guard let declaration = lines.firstIndex(where: { $0.contains("public static func \(member)(") }),
              let open = lines[declaration...].firstIndex(where: { $0.contains("let query: [String: Any] = [") }),
              !lines[(declaration + 1)..<open].contains(where: { $0.contains("static func ") }) else { return [] }
        var found: [(key: String, value: String)] = []
        // R2: bounded by the file's remaining lines.
        for line in lines[(open + 1)...] {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry != "]" else { return found }
            let parts = entry.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                .components(separatedBy: " as String: ")
            guard parts.count == 2 else { return [] }
            found.append((key: parts[0], value: parts[1]))
        }
        return []
    }

    /// `SynchronizableScope.queryValue`'s `case .x: return y` arms, by case name.
    private static func scopeArms(in lines: [String]) -> [String: String] {
        guard let getter = lines.firstIndex(where: { $0.contains("var queryValue: Any {") }) else { return [:] }
        var arms: [String: String] = [:]
        // R2: bounded by the eight lines after the getter, which hold its three arms.
        for line in lines[(getter + 1)...].prefix(8) {
            let words = line.split(separator: " ").map(String.init)
            guard words.count == 4, words[0] == "case", words[2] == "return",
                  words[1].hasPrefix("."), words[1].hasSuffix(":") else { continue }
            arms[String(words[1].dropFirst().dropLast())] = words[3]
        }
        return arms
    }
}

// MARK: - The audit lines one call writes

/// The `FernletAuditLog` lines one synchronous call writes, captured as `ProximityAuditBridgeTests`
/// captures them: the handler records only while a task-local mark bound around that call is visible,
/// so no line from a suite running beside this one is counted, and the capture is read the moment the
/// call returns. Group 15 compares the copy's two delete lines with FernletFoundation's through it.
private enum KeychainAuditLines {

    /// One line as a capture handler saw it.
    struct Line: Equatable, Sendable {
        /// The event name.
        let event: String
        /// The context.
        let context: [String: String]
    }

    /// The mark, bound only around the call being captured.
    @TaskLocal static var emitter: UUID?

    /// Every line written while `emit` ran under this call's own mark, in order.
    ///
    /// - Parameter emit: The synchronous call.
    /// - Returns: The lines it wrote.
    static func delivered(during emit: () -> Void) -> [Line] {
        let mark = UUID()
        let seen = OSAllocatedUnfairLock<[Line]>(initialState: [])
        let token = FernletAuditLog.addCaptureHandler { event, context in
            guard Self.emitter == mark else { return }
            seen.withLock { $0.append(Line(event: event, context: context)) }
        }
        defer { FernletAuditLog.removeCaptureHandler(token) }
        Self.$emitter.withValue(mark) { emit() }
        return seen.withLock { $0 }
    }
}
