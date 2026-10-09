// FernletRoutedTypes.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.9 (seam S16): Fernlet's routed-type rows, declared by the host rather
// than resident in the mesh engine. The engine builds its routed type registry from the host's rows
// alone since plan step A0.5.11 (`ProximityHost.meshRoutedTypeEntries`, its resident rows until then);
// FernletStore answers this file's `entries`, and the test target's host doubles answer the same. A row
// moved here with its feature, spelled exactly as the engine's registry spelled it, each cap the same
// formula over the moved body's constants: the temporary-message row with chat (A0.5.9), the heart row
// with hearts (A0.5.10) and the photo row with photos (A0.5.11), the last of them.
//
// The one FernletSocial file that reads a routed type off the namespace (the field-homes wall in
// `MeshRoutedStoreIsolationTests`): the composition registers each feature's projection or ledger
// adapter, and each sender mints, under its row's token from here, so a host with another namespace
// registers and mints under its own spellings. The registry is token-keyed, so the order of these rows
// reaches no door and no byte.

import Foundation
import PrivateMediaStore
import ProximityKit

/// Fernlet's routed-type rows by name, each built from the routed types of the namespace the host
/// holds (plan step A0.5.9, S16): every row the mesh registers (since plan step A0.5.11, when its last
/// resident row, the photo row, joined them).
///
/// A value: the mesh still admits, resolves and forwards by its own registry alone, built once from
/// ``entries``, and asks that registry whether a row is registered before a sender mints under the
/// row's token. The rows by name say which token is whose — the token the chat sends under and the
/// composition registers its projection adapter under, the token the session hearts send under and
/// the composition registers their ledger judge under, and the token the session photos send under and
/// the composition registers their projection adapter under — and ``entries`` hands them all to the
/// host's ``ProximityHost/meshRoutedTypeEntries``.
public nonisolated struct FernletRoutedTypes: Equatable, Sendable {

    /// The temporary-message row: the live-session chat's routed type (P6 item 4), FernletSocial's
    /// since the chat left the engine (plan step A0.5.9).
    public let text: MeshRoutedTypeEntry

    /// The heart row: the in-session hearts' routed type (P6 item 6), whose final ack is the ledger
    /// judgement, FernletSocial's since the hearts left the engine (plan step A0.5.10).
    public let heart: MeshRoutedTypeEntry

    /// The photo row: the session photos' routed type (P5 item 13), the widest row and so the mesh's
    /// resident-blob bound, FernletSocial's since the photos left the engine (plan step A0.5.11).
    public let photo: MeshRoutedTypeEntry

    /// Fernlet's rows over `routedTypes`, each row's token read off them: this file spells no routed
    /// type of its own.
    ///
    /// - Parameter routedTypes: The routed types of the namespace the host holds.
    public init(_ routedTypes: ProximityNamespace.RoutedTypes) {
        // The text row's cap is the SECOND narrowed one (P6 item 4), and narrowed the same way as the
        // photo row's: `MeshRoutedTextBody.maxSealedBlobByteCount` is the sanitized maximum's own byte
        // bound (16 × `SessionMessageStore.maxTextLength`, because the product's cap is 500
        // *Characters* and a grapheme cluster is unbounded in bytes) plus this body family's framed
        // header allowance plus the seal's overhead — 9 065 B. Defined as that constant, never as a
        // copy, so the mint's own refusal and the manifest door's `sizeExceedsTypeCap` are one number.
        // `contentScope` and `maxItemByteCount` are the two columns the freezing rule leaves editable
        // in place, so this needs no amendment to it.
        self.text = MeshRoutedTypeEntry(
            token: routedTypes.tempMessage,
            maxItemByteCount: UInt64(MeshRoutedTextBody.maxSealedBlobByteCount),
            destinations: .fullRosterAtCreation,
            relayRetention: .originRetainsUntilDeparture,
            finalAck: .durableRecipientStorage,
            expiry: .meshHardDeadlinePlusGrace,
            contentScope: .session
        )
        // The heart row's cap is the THIRD narrowed one (P6 item 6), and its formula has a **zero**
        // payload term: a heart body is header-only, so the widest ciphertext it can measure is
        // this family's framed header allowance plus the seal's overhead. `destinations` is
        // `.singleRecipient` since item 6 — the one re-declaration the freezing rule (ProximityKit's
        // `MeshRoutedTypeEntry`) allows a never-minted row, and it is spent.
        self.heart = MeshRoutedTypeEntry(
            token: routedTypes.heart,
            maxItemByteCount: UInt64(MeshRoutedHeartBody.maxSealedBlobByteCount),
            destinations: .singleRecipient,
            relayRetention: .originRetainsUntilDeparture,
            finalAck: .foregroundDecryptAndLedgerCommit,
            expiry: .meshHardDeadlinePlusGrace,
            contentScope: .persistent
        )
        // The photo row is the FIRST narrowed cap (P6 item 3, D-11.4), and it is narrowed to a
        // formula rather than a number: `PrivateMediaStore.maxIncomingPhotoBytes` (the photo
        // wall's PLAINTEXT bound) plus `MeshRoutedPhotoBody.maxFramedHeaderByteCount` plus the
        // seal's own overhead — i.e. the widest CIPHERTEXT a routed photo can measure, 10 551 337 B.
        // Each term is read from the type that owns it, never copied. The formula was the seal
        // file's resident bound until plan step A0.5.4 moved it to the engine's resident row, and it
        // moved here with the photos at plan step A0.5.11: the bound is the registry's widest row,
        // which this row is, so the manifest door's check and the projection's resident-blob guard
        // are the same number and cannot drift; see the unit caveat on `MeshRoutedTypeEntry`.
        self.photo = MeshRoutedTypeEntry(
            token: routedTypes.photo,
            maxItemByteCount: UInt64(
                PrivateMediaStore.maxIncomingPhotoBytes
                    + MeshRoutedPhotoBody.maxFramedHeaderByteCount
                    + MeshRoutedItemSealFormat.overheadByteCount
            ),
            destinations: .fullRosterAtCreation,
            relayRetention: .originRetainsUntilDeparture,
            finalAck: .durableRecipientStorage,
            expiry: .meshHardDeadlinePlusGrace,
            contentScope: .persistent
        )
    }

    /// Every row, the whole of the mesh's registry: the temporary-message row, the heart row and the
    /// photo row. The registry is token-keyed, so their order reaches no door and no byte.
    public var entries: [MeshRoutedTypeEntry] { [text, heart, photo] }

    /// The rows a host answers ``ProximityHost/meshRoutedTypeEntries`` with:
    /// `FernletRoutedTypes(routedTypes).entries`.
    ///
    /// - Parameter routedTypes: The routed types of the namespace the host holds.
    /// - Returns: Every Fernlet row, each under its token in `routedTypes`.
    public static func entries(_ routedTypes: ProximityNamespace.RoutedTypes) -> [MeshRoutedTypeEntry] {
        FernletRoutedTypes(routedTypes).entries
    }
}
