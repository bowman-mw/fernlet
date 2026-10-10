// MeshRoutedHeartBody.swift
// FernletSocial/HeartSharing
//
// Network migration P6 item 6 (plan §12's heart row): the PLAINTEXT a routed heart carries — what the
// engine seals for the session hearts' sender and what its one opener decodes for the heart row's ledger
// judge: the header and the body, whose allowance and cap are the body's own constants.
//
// The framing is the family's frozen one, `u64BE(headerJSON.count) ‖ headerJSON`, with no payload half,
// written with ProximityKit's public byte writer and coders, so the bytes cannot drift from the photo and
// text bodies'. A body that refuses a shape throws ProximityKit's ``MeshRoutedItemSealError/malformed``,
// so the engine's `mesh.routedHeart.openFailed` line spells every family's refusal the same way.
//
// Not here: any key, any store, any clock, any dispatch. This file is a value and its wire shape.

import FernletDomainModel
import Foundation
import ProximityKit

// MARK: - MeshRoutedHeartHeader

/// The whole plaintext of a routed heart, minus its framing: a gift id, the day the sender says it
/// was sent, and the sender's display name (P6 item 6).
///
/// Frozen JSON keys (invariant 8). Unknown fields are ignored on decode, and no key is ever reused
/// for a new meaning.
///
/// **``id`` IS the gift id, and it MUST equal the manifest's item id.** For
/// ``ProximityNamespace/RoutedTypes/heart`` that equality is the type's frozen contract rather than a
/// convenience: `ProximityHeartLedger` dedups on the gift id, `MeshRoutedHeartAck` refuses any
/// proof whose `giftID` is not the item's, and the replay window, the delivery target and the
/// ledger therefore all key on one value with no second mapping table. The receiver enforces it in
/// the engine's one generic opener (ProximityKit's `MeshRoutedItemDelivery.openBody`, through
/// ``MeshRoutedHeartBody/routedItemID``) exactly as it does for a photo, so it is a fact about what a
/// receiver accepts and not only an obligation on the mint.
///
/// Carries **no identity claim**: who sent this is `manifest.originFingerprint`, signed, and the
/// signing key is the admission ledger's roster entry for that origin. The display name is the one
/// exception and it is display copy — see ``senderName``.
nonisolated struct MeshRoutedHeartHeader: Codable, Equatable, Sendable {

    /// The gift id, equal to the routed item id the manifest signs.
    let id: UUID

    /// The day key the sender stamped, `yyyy-MM-dd` — `HeartPayload`'s own field, carried for
    /// parity with the transport this row replaced and shape-checked on receive.
    ///
    /// **Read by nothing, and that was true of the legacy path too**: the retired handler validated
    /// this field and then discarded it, because `ProximityHeartLedger.recordReceivedHeart` takes no
    /// instant. The authenticated instant for a routed heart is `manifest.createdAt`, and the
    /// receiver's own is the index record's `firstSeenAt`. Kept rather than dropped because dropping
    /// a field from a registered type's body is a `…heart.v2` decision, not a v1 edit; refused
    /// rather than coerced on receive, because it is a peer's claim in a fixed shape.
    let sentAtDayKey: String

    /// The origin's display name, as the sender chose to show it. Display copy, never a token.
    ///
    /// A claim, exactly as the chat's `MeshRoutedTextHeader.senderName` and ProximityKit's
    /// `MeshRoutedPhotoHeader.senderName` are, and for the same reason: the admission ledger holds
    /// no name (`MeshRosterMember` is a fingerprint, a signing key and an admission instant), while
    /// `recordReceivedHeart(senderDisplayName:)` needs one. It is **stronger** than what the legacy
    /// transport used, which was the envelope's unsigned `senderDisplayName`: here the claim sits
    /// inside an AEAD blob bound to the signed origin. Re-moderated at the receiver with
    /// `ProximityDisplayName.peerDisplayName(_:in:)`, and its LENGTH refused rather than coerced
    /// (``MeshRoutedHeartBody/maxSenderNameUTF8ByteCount``).
    let senderName: String

    /// Builds the header of a routed heart body.
    init(id: UUID, sentAtDayKey: String, senderName: String) {
        self.id = id
        self.sentAtDayKey = sentAtDayKey
        self.senderName = senderName
    }
}

// MARK: - MeshRoutedHeartBody

/// The complete plaintext of a routed heart item — a ``MeshRoutedHeartHeader`` and **nothing else**
/// (P6 item 6).
///
/// The third routed body family (the photo body is the session photos', the text body the chat's), and the
/// first with no payload half. It keeps the family's frozen framing anyway —
/// `u64BE(headerJSON.count) ‖ headerJSON`, with the payload length zero — rather than shipping bare
/// JSON, for three reasons: one framing means one place a coder option can
/// move, `MeshRoutedItemSealer` refuses an empty plaintext by name
/// (``MeshRoutedItemSealError/emptyPlaintext``: "a routed item with no payload is a manifest, not an
/// item") and a framed header is not empty, and a future `…heart.v2` that carries something can add
/// it without a framing change.
///
/// One thing it does that its two siblings do not: it **refuses a non-empty remainder**. A photo's
/// remainder is the image and a message's is the text, so both read to the end of the plaintext; a
/// heart's remainder is nothing, and bytes an authenticated blob carries but nobody reads are a
/// malleability seam inside it.
///
/// A ``MeshRoutedBody`` (plan step A0.5.2), like its two siblings.
nonisolated struct MeshRoutedHeartBody: Equatable, Sendable, MeshRoutedBody {

    /// The widest display name a routed heart header will carry, in bytes.
    ///
    /// The same figure and the same reasoning as FernletSocial's
    /// `MeshRoutedTextBody.maxSenderNameUTF8ByteCount` — the host's peer-name cap is 24 **Characters**
    /// for Fernlet and a grapheme cluster is unbounded in bytes — and here it does more work than
    /// there, because the name is this header's only variable-length field at all: the row's whole
    /// cap is arithmetic over this bound. Enforced at
    /// the mint (``bounded(senderName:)``) and on the WIRE (a wider decoded name is
    /// ``MeshRoutedItemSealError/malformed``), so the cap cannot be breached from either end.
    static let maxSenderNameUTF8ByteCount = 128

    /// What a ``MeshRoutedHeartHeader``'s JSON is allowed inside the heart row's ciphertext cap —
    /// 512 bytes.
    ///
    /// Narrower than the text family's 1 KiB because the header is narrower: a UUID (36 bytes
    /// quoted), a ten-character day key and one name bounded at 128 bytes, which measures ~215 B at
    /// its widest. `theHeartHeaderAllowanceCoversAMaximalHeader` is that claim, measured rather than
    /// asserted, at the text family's 2× floor rather than the photo family's 8× — and the
    /// difference is a fact about the headers, not a weaker standard: a photo header absorbs a
    /// gossiped list of up to 32 peer-supplied names, a heart header has one field this file bounds.
    ///
    /// Not a second refusal: nothing enforces a header bound on receive (the framing is frozen and
    /// carries none). What refuses an over-wide header is the type cap at the manifest door and the
    /// sealer's own `plaintextTooLarge`, at both ends.
    static let maxHeaderJSONByteCount = 512

    /// The framed heart header's allowance: the u64 length prefix plus ``maxHeaderJSONByteCount``.
    /// Derived, never written twice.
    static let maxFramedHeaderByteCount =
        MeshRoutedItemBodyFormat.headerLengthPrefixByteCount + maxHeaderJSONByteCount

    /// The heart row's registry cap: the widest CIPHERTEXT a routed heart can measure, stated as a
    /// formula beside the photo and text rows' (P6 item 3's idiom, D-11.4).
    ///
    /// ```
    /// maxSealedBlobByteCount
    ///   = 0                                          // a heart body has NO payload half
    ///   + maxFramedHeaderByteCount                   // this family's framed header
    ///   + MeshRoutedItemSealFormat.overheadByteCount // marker + nonce + tag
    /// ```
    ///
    /// 520 + 33 = **553 B**. Every term is read from the type that owns it, so the number the
    /// manifest door checks and the number this device can produce are the same number by
    /// construction. It replaces `MeshRoutedManifestFormat.maxContentByteCount` (256 MiB) on the
    /// row, which is what makes `sizeExceedsTypeCap` reachable for a heart at all and what bounds a
    /// hostile origin's heart to half a kilobyte instead of a quarter of a gigabyte.
    static let maxSealedBlobByteCount =
        maxFramedHeaderByteCount + MeshRoutedItemSealFormat.overheadByteCount

    /// The metadata half, which is the whole body.
    let header: MeshRoutedHeartHeader

    /// The routed item id this body claims: its header's id — the gift id — which must equal the id
    /// the origin signed.
    var routedItemID: UUID { header.id }

    /// Builds a routed heart body.
    init(header: MeshRoutedHeartHeader) {
        self.header = header
    }

    /// `name` with whole trailing `Character`s dropped until it fits
    /// ``maxSenderNameUTF8ByteCount`` — the mint's own bound, so the sender cannot breach its own
    /// row's cap with its own display name.
    ///
    /// - Parameter senderName: The local display name to carry.
    /// - Returns: the name, at most ``maxSenderNameUTF8ByteCount`` UTF-8 bytes long.
    static func bounded(senderName: String) -> String {
        guard senderName.utf8.count > maxSenderNameUTF8ByteCount else { return senderName }
        var kept = senderName
        // R2: bounded by the input's own Character count; each pass removes exactly one Character.
        while !kept.isEmpty, kept.utf8.count > maxSenderNameUTF8ByteCount {
            kept.removeLast()
        }
        return kept
    }

    /// Decodes a body from the sealed plaintext.
    ///
    /// The header length is bounded against the bytes that remain **before** anything is sliced, so
    /// a hostile prefix yields ``MeshRoutedItemSealError/malformed`` rather than a trap or a
    /// truncated read.
    ///
    /// **FOUR hostile shapes for a heart**, all landing on that one frozen token: too short to carry
    /// the prefix, a prefix past the remaining bytes, an in-bounds slice that is not the header's
    /// JSON, and **a non-empty remainder** — the shape this family adds, because a heart body ends
    /// at its header. Two field-level refusals ride with them, and both are shapes rather than
    /// judgements: a `senderName` above ``maxSenderNameUTF8ByteCount``, and a `sentAtDayKey` that is
    /// not `HeartPayload`'s ten-character `yyyy-MM-dd` (the retired handler's own check, kept at the
    /// same position in the pipeline).
    init(decoding bytes: Data) throws {
        let prefixWidth = MeshRoutedItemBodyFormat.headerLengthPrefixByteCount
        guard bytes.count >= prefixWidth else { throw MeshRoutedItemSealError.malformed }
        let start = bytes.startIndex
        var headerLength: UInt64 = 0
        // R2: bounded by the fixed prefix width.
        for byte in bytes[start..<(start + prefixWidth)] {
            headerLength = (headerLength << 8) | UInt64(byte)
        }
        guard headerLength <= UInt64(bytes.count - prefixWidth) else {
            throw MeshRoutedItemSealError.malformed
        }
        let headerEnd = start + prefixWidth + Int(headerLength)
        let decoded: MeshRoutedHeartHeader
        do {
            decoded = try MeshRoutedItemBodyFormat.headerDecoder()
                .decode(MeshRoutedHeartHeader.self, from: Data(bytes[(start + prefixWidth)..<headerEnd]))
        } catch {
            throw MeshRoutedItemSealError.malformed
        }
        guard headerEnd == bytes.endIndex else { throw MeshRoutedItemSealError.malformed }
        guard decoded.senderName.utf8.count <= Self.maxSenderNameUTF8ByteCount else {
            throw MeshRoutedItemSealError.malformed
        }
        guard HeartPayload.isValidDayKey(decoded.sentAtDayKey) else {
            throw MeshRoutedItemSealError.malformed
        }
        header = decoded
    }

    /// The framed plaintext: `u64BE(headerJSON.count) ‖ headerJSON`, with no payload half.
    func encoded() throws -> Data {
        let headerJSON = try MeshRoutedItemBodyFormat.headerEncoder().encode(header)
        var writer = CanonicalByteWriter()
        writer.appendLengthPrefixed(headerJSON)
        return writer.bytes
    }
}
