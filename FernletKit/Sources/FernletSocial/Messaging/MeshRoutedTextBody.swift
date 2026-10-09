// MeshRoutedTextBody.swift
// FernletSocial/Messaging
//
// Network migration P6 item 4 (plan §12's temporary-text row): the PLAINTEXT a routed text item
// carries — what the engine seals for the chat's sender and what its one opener decodes for the chat's
// projection handler: the text family's header allowance (an extension of ProximityKit's public
// ``MeshRoutedItemBodyFormat``, whose framing constants and coders the family shares with this
// module's photo and heart bodies), the header and the body.
//
// The framing is the family's frozen one, `u64BE(headerJSON.count) ‖ headerJSON ‖ text.utf8`, written
// with ProximityKit's public byte writer and coders, so the bytes cannot drift from the photo and heart
// bodies'. A body that refuses a shape throws ProximityKit's ``MeshRoutedItemSealError/malformed``, so
// the engine's `mesh.routedProjection.openFailed` line spells every family's refusal the same way.
//
// Not here: any key, any store, any clock, any dispatch. This file is a value and its wire shape.

import Foundation
import ProximityKit

// MARK: - The text family's header allowance

/// The text family's header allowance inside the routed body's frozen framing: a term of the text
/// row's ciphertext cap (`FernletRoutedTypes`), beside the photo and heart families' own.
nonisolated extension MeshRoutedItemBodyFormat {

    /// What a ``MeshRoutedTextHeader``'s JSON is allowed inside the text row's ciphertext cap — 1 KiB.
    ///
    /// The same kind of figure as the photo body's `MeshRoutedPhotoBody.maxHeaderJSONByteCount`
    /// (this module's too, beside the photo row) and narrowed for one reason: it is a term of the
    /// text row's **cap** (`maxItemByteCount`), and the photo's 64 KiB would make that cap
    /// 73 577 B while a maximal text header measures ~210 B. A cap
    /// four times the widest honest body is a bound; a cap three hundred times it is decoration,
    /// and it hands a hostile origin 64 KiB of header per message inside a row whose payload bound is
    /// 8 000 B.
    ///
    /// Not a second refusal either: nothing enforces a header bound on receive (the framing is
    /// frozen and carries none). What refuses an over-wide header is the type cap at the manifest
    /// door and the sealer's own `plaintextTooLarge`, at both ends.
    ///
    /// `theTextHeaderAllowanceCoversAMaximalHeader` is the same measured claim the photo header's
    /// twin makes, at a **4× floor rather than 8×** — and the difference is a fact about the two
    /// headers, not a weaker standard. The photo header's dominant term is a gossiped list of up to
    /// 32 participants whose names arrive from peers, so its allowance has to absorb growth it does
    /// not control. A text header is a UUID, a date and ONE display name whose byte bound
    /// ``MeshRoutedTextBody/maxSenderNameUTF8ByteCount`` sets in this file.
    static let maxTextHeaderJSONByteCount = 1024

    /// The framed text header's allowance: the u64 length prefix plus
    /// ``maxTextHeaderJSONByteCount``. Derived, never written twice.
    static let maxFramedTextHeaderByteCount = headerLengthPrefixByteCount + maxTextHeaderJSONByteCount
}

// MARK: - MeshRoutedTextHeader

/// The metadata half of a routed **text** body: everything the session transcript needs about one
/// message that is not the message itself (P6 item 4, plan §12's temporary-text row).
///
/// Frozen JSON keys (invariant 8). Unknown fields are ignored on decode, and no key is ever reused
/// for a new meaning.
///
/// **``id`` MUST equal the manifest's item id, and the delivery door enforces it** — the guard
/// ProximityKit's `MeshRoutedPhotoHeader` tells a P6 body type to copy or to say why its id is no
/// key. Text's id *is* a key: ``SessionMessageStore`` dedups on it (`seenKeys`, which deliberately
/// never forgets a dropped key), so a body carrying another member's message id would consume that
/// id's dedup slot.
/// `MeshRoutedItemDelivery.openBody` closes it with `MeshRoutedDeliveryError.bodyIdentityMismatch`,
/// reading this field as ``MeshRoutedTextBody/routedItemID``.
///
/// **``senderName`` is a display CLAIM, exactly as the photo header's is** — and that is a decision,
/// not an oversight. The identity is bound elsewhere and more strongly: the author is
/// `manifest.originFingerprint`, signed, resolved against `admissions − removals` with the block
/// list applied before the unwrap (D-13.33), and that fingerprint is what the transcript row
/// carries. The ledger holds **no name at all** (`MeshRosterMember` is a fingerprint, a signing key
/// and an admission instant; `MeshAdmissionToken` has no name field), so a projection that refused
/// to take the name from the body would have to take it from the memory-only session roster — which
/// a restart, an idle-lapse resume or a rejoin does not restore — or from the gossiped descriptor,
/// which is strictly WEAKER because a descriptor carries rows for fingerprints other than the
/// sender's. `SessionMessageStore.receiveIncoming` re-applies
/// `ProximityDisplayName.peerDisplayName(_:in:)` to it, so the arm adds no second moderation. Its
/// LENGTH, unlike its content, is refused rather than coerced: a decoded name above
/// ``MeshRoutedTextBody/maxSenderNameUTF8ByteCount`` is `malformed` (P6 item 4 fix review, P3-1).
nonisolated struct MeshRoutedTextHeader: Codable, Equatable, Sendable {

    /// The message id, equal to the routed item id the manifest signs.
    let id: UUID
    /// When the origin sent it — plan §10.3's `claimedSentAt`, clamped before it orders anything.
    let sentAt: Date
    /// The origin's display name, as the sender chose to show it. Display copy, never a token.
    let senderName: String

    /// Builds the header half of a routed text body.
    init(id: UUID, sentAt: Date, senderName: String) {
        self.id = id
        self.sentAt = sentAt
        self.senderName = senderName
    }
}

// MARK: - MeshRoutedTextBody

/// The complete plaintext of a routed text item: a ``MeshRoutedTextHeader`` and the message's own
/// UTF-8 bytes (P6 item 4).
///
/// Sealed by ProximityKit's `MeshRoutedItemSealer` under the item's own content key, so its bytes are what
/// `manifest.contentHash` and `manifest.size` measure once the seal has added its 33 bytes.
///
/// The framing is the family's frozen one — see ``MeshRoutedItemBodyFormat`` — with the text carried
/// RAW and running to the end of the body, which is why no second length prefix exists. A `String`
/// inside one `Codable` blob would be escaped and re-normalised by `JSONEncoder`, so the same
/// message would not produce the same bytes on every build.
///
/// A ``MeshRoutedBody`` (plan step A0.5.2), so the engine's one generic opener decodes it for the
/// temporary-message row's projection handler.
nonisolated struct MeshRoutedTextBody: Equatable, Sendable, MeshRoutedBody {

    /// The widest message this device will put on the wire, as a formula rather than a literal:
    /// sixteen bytes per `Character` of `SessionMessageStore.maxTextLength`.
    ///
    /// **The sanitized maximum has no byte bound at all, which is why this exists.**
    /// `SessionMessageStore.sanitize` caps with `prefix(maxTextLength)` — 500 **`Character`s** —
    /// and a `Character` is a grapheme cluster of unbounded length: combining marks are neither
    /// control characters nor in the sanitizer's invisible-scalar list, so `"a"` plus a thousand
    /// combining acutes is ONE Character and 2 001 bytes. Sixteen bytes per Character covers any
    /// plausible honest message (a flag is 8 bytes, a skin-toned emoji 8, a base plus two marks 5)
    /// and keeps the whole item inside a single chunk.
    ///
    /// Enforced at the SENDER (``boundedText(_:)``), so the bound is never a surprise refusal for
    /// honest input; the receiver never needs it, because `receiveIncoming` re-sanitizes and
    /// re-caps at 500 Characters, so 8 000 ASCII bytes still displays as 500 characters.
    static let maxTextUTF8ByteCount = 16 * SessionMessageStore.maxTextLength

    /// The widest display name this device will put in a text header, in bytes.
    ///
    /// The host's peer-name cap (24 **Characters** for Fernlet) has the same unbounded-in-bytes
    /// property the text cap exists for, so the header's own field is byte-bounded too — otherwise
    /// one long grapheme cluster in the local user's own name could push the header past
    /// ``MeshRoutedItemBodyFormat/maxTextHeaderJSONByteCount`` and the seal would refuse the whole
    /// message by name with nothing the user could act on.
    ///
    /// 128 bytes covers 24 Characters of anything but a name made entirely of the widest clusters
    /// (a flag is 8 bytes, so 16 of them fit), and it is what keeps a maximal header at a quarter of
    /// its allowance: the name is the header's ONLY variable-length field, so bounding it here is
    /// what makes the allowance a statement about this family rather than a hope.
    ///
    /// **Enforced on the WIRE as well as at the sender** (P6 item 4 fix review, P3-1): a body whose
    /// decoded name exceeds it is ``MeshRoutedItemSealError/malformed``. The name is a peer's claim
    /// rather than honest input this device produced, and it is the only variable-length field a
    /// shipped sender writes into the header — so refusing a wider one refuses a shape no shipped
    /// sender can mint.
    ///
    /// **The bound measures the NAME, not the header** (P6 item 4 fix review P3-3, taken in item 7 —
    /// the earlier wording over-claimed). Nothing compares the framed header against
    /// ``MeshRoutedItemBodyFormat/maxFramedTextHeaderByteCount`` on receive: `JSONDecoder` ignores
    /// unknown keys, so a header padded with a key nobody reads — or this same 128-byte name written
    /// as `\u00nn` escapes, or spread with inter-token whitespace — still decodes, bounded only by
    /// the seal's own ``maxSealedBlobByteCount``. The family's "an allowance, not a refusal"
    /// doctrine therefore stands unbroken for the header; this is a refusal about one field.
    static let maxSenderNameUTF8ByteCount = 128

    /// The text row's registry cap: the widest CIPHERTEXT a routed text item can measure, stated as
    /// a formula beside the photo row's (P6 item 3's idiom, D-11.4).
    ///
    /// ```
    /// maxSealedBlobByteCount
    ///   = maxTextUTF8ByteCount                                   // the PLAINTEXT payload bound
    ///   + MeshRoutedItemBodyFormat.maxFramedTextHeaderByteCount  // this family's framed header
    ///   + MeshRoutedItemSealFormat.overheadByteCount             // marker + nonce + tag
    /// ```
    ///
    /// Every term is read from the type that owns it, so the number the manifest door checks and
    /// the number this device can produce are the same number by construction. 8 000 + 1 032 + 33 =
    /// **9 065 B**.
    static let maxSealedBlobByteCount = maxTextUTF8ByteCount
        + MeshRoutedItemBodyFormat.maxFramedTextHeaderByteCount
        + MeshRoutedItemSealFormat.overheadByteCount

    /// The metadata half.
    let header: MeshRoutedTextHeader
    /// The message, already sanitized and byte-bounded by the sender.
    let text: String

    /// The routed item id this body claims: its header's id, which must equal the id the origin
    /// signed.
    var routedItemID: UUID { header.id }

    /// Builds a routed text body from its two halves.
    init(header: MeshRoutedTextHeader, text: String) {
        self.header = header
        self.text = text
    }

    /// `text` with whole trailing `Character`s dropped until it fits ``maxTextUTF8ByteCount``.
    ///
    /// A **wire** bound, deliberately not folded into `SessionMessageStore.sanitize`: that function
    /// is the product's Character cap and is also the receive-side coercion, so putting a wire
    /// constant in it would make one number answer two questions. Character-aligned, because
    /// truncating UTF-8 mid-cluster is how a sanitizer produces a scalar nobody wrote.
    ///
    /// **It can return the empty string** — one base plus four thousand combining marks is a single
    /// Character above the bound — so the sender re-checks emptiness after calling it rather than
    /// minting and echoing an empty row (the design check's finding A3b).
    ///
    /// - Parameter text: The sanitized message.
    /// - Returns: the message, at most ``maxTextUTF8ByteCount`` UTF-8 bytes long.
    static func boundedText(_ text: String) -> String {
        bounded(text, toUTF8ByteCount: maxTextUTF8ByteCount)
    }

    /// ``boundedText(_:)``'s rule for the header's display name, at its own bound.
    ///
    /// - Parameter name: The display name to carry.
    /// - Returns: the name, at most ``maxSenderNameUTF8ByteCount`` UTF-8 bytes long.
    static func boundedSenderName(_ name: String) -> String {
        bounded(name, toUTF8ByteCount: maxSenderNameUTF8ByteCount)
    }

    /// Drops whole trailing `Character`s until the UTF-8 bound holds.
    private static func bounded(_ text: String, toUTF8ByteCount limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = text
        // R2: bounded by the input's own Character count, which `sanitize` caps at
        // `SessionMessageStore.maxTextLength`; each pass removes exactly one Character.
        while !kept.isEmpty, kept.utf8.count > limit {
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
    /// **FIVE hostile shapes for text**, all landing on that one frozen token: too short to carry
    /// the prefix, a prefix past the remaining bytes, an in-bounds slice that is not the header's
    /// JSON, **payload bytes that are not valid UTF-8** — and a decoded ``MeshRoutedTextHeader``
    /// whose `senderName` exceeds ``maxSenderNameUTF8ByteCount`` (P6 item 4 fix review, P3-1: the
    /// name is the header's only variable-length field a shipped sender writes — and only the name,
    /// never the framed header itself, which stays an allowance). The fourth is text's
    /// own, and it is the one a copy of ``MeshRoutedPhotoBody/init(decoding:)`` gets wrong:
    /// `String(decoding:as:)` **cannot fail**, it substitutes U+FFFD, and U+FFFD is neither a
    /// control character nor in `SessionMessageStore.sanitize`'s invisible-scalar list — so the
    /// tempting spelling silently admits arbitrary bytes as replacement characters and displays
    /// them. Refuse, do not repair.
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
        let headerJSON = Data(bytes[(start + prefixWidth)..<headerEnd])
        let decoded: MeshRoutedTextHeader
        do {
            decoded = try MeshRoutedItemBodyFormat.headerDecoder()
                .decode(MeshRoutedTextHeader.self, from: headerJSON)
        } catch {
            throw MeshRoutedItemSealError.malformed
        }
        guard decoded.senderName.utf8.count <= Self.maxSenderNameUTF8ByteCount else {
            throw MeshRoutedItemSealError.malformed
        }
        guard let decodedText = String(data: Data(bytes[headerEnd...]), encoding: .utf8) else {
            throw MeshRoutedItemSealError.malformed
        }
        header = decoded
        text = decodedText
    }

    /// The framed plaintext: `u64BE(headerJSON.count) ‖ headerJSON ‖ text.utf8`.
    func encoded() throws -> Data {
        let headerJSON = try MeshRoutedItemBodyFormat.headerEncoder().encode(header)
        var writer = CanonicalByteWriter()
        writer.appendLengthPrefixed(headerJSON)
        return writer.bytes + Data(text.utf8)
    }
}
