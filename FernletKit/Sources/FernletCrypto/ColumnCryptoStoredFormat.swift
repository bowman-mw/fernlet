// ColumnCryptoStoredFormat.swift
// FernletCrypto
//
// The keyless marker-byte classifier for stored sealed-column blobs — the counting
// half of the format census that gates Phase 3 of
// Docs/Plan-Crypto-Standardization-2026-08-27.md ("delete the legacy readers only
// once the number is known and observed to reach zero").

import Foundation

/// Which at-rest generation a stored sealed-column blob's **marker byte** says it is.
///
/// This is the one place outside ``ColumnCrypto/openBlob(_:contentKey:)`` that encodes the
/// sealed-column marker semantics (`0x03` → v3, `0x02` → v2, anything else → unprefixed
/// legacy). It exists so the Phase 0 census can count the corpus **without a content key and
/// without ever decrypting anything** — the plan's stated risk control is "count by MARKER
/// BYTES only — never open a blob to classify it", because a census that had to decrypt could
/// only ever run while the private area is unlocked, and would be a second, unreviewed reader
/// of the sealed corpora.
///
/// ## What the buckets actually prove
///
/// The marker byte is **not** a reliable discriminator, and since Phase 3 the shipping reader
/// has no way around that either: a legacy blob is a bare ChaChaPoly `combined` value, so its
/// first byte is the first byte of a random 12-byte nonce, which equals `0x03` or `0x02` with
/// probability 1/256 each (2 in 256, ≈0.78%, overall). `openBlob` used to disambiguate by
/// attempted decrypt — try the marked path, then fall back unconditionally to the legacy open —
/// but the lower rungs are gone (owner decision D2), so it now dispatches on the marker byte and
/// nothing else, refusing ``v2Marked`` and ``unprefixed`` as
/// `SealedColumnOpenError.retiredFormat`. Reader and census read the same byte the same way, so
/// this classifier is no longer the weaker of the two: neither can see through a collision.
/// Therefore:
///
/// - ``unprefixed`` is **exact**. A blob whose first byte is neither marker cannot be anything
///   but legacy, so `count(unprefixed)` is a precise, keyless lower bound on the legacy
///   population — and it is precisely the number Phase 3's "census = 0" gate needs to watch.
/// - ``v3Marked`` and ``v2Marked`` are **upper bounds** on their generations. Each bucket may
///   contain the ~1/256 sliver of legacy blobs whose nonce collided with that marker. The keyed
///   pass that could once resolve it — `SealedColumnFormatMigrator`, which opened each blob and
///   observed which rung succeeded — converted THROUGH the rungs Phase 3 deleted and was deleted
///   with them. **Nothing in the app can resolve the collided sliver any more**, so the sliver is
///   now permanent rather than pending.
///
/// So a census reading `unprefixed == 0` is **necessary but not sufficient** proof that no
/// legacy row remains: the collided sliver is invisible to any byte-only classifier. Say so
/// wherever the number is reported; do not present the marked counts as exact.
///
/// ## Two more honesty notes for whoever reads a census number
///
/// - **The number can no longer go up.** `ColumnCrypto.sealPlaintextV3Strict` — the one seal
///   entry — *fails closed*: when `DeviceBindingID.current()` returns `nil` (no durable install
///   binding — a fresh keychain, a keychain the device cannot read yet) it throws
///   `SealedColumnStrictSealError.bindingUnavailable` rather than writing an unprefixed legacy
///   blob. Through Phase 2.6 it fell open, so a census reading was a moment in time that the next
///   write could undo; Phase 3 closed that branch (owner decision D4), and the legacy population
///   is now monotonically non-increasing on any given install. A restored iOS backup can still
///   re-introduce older rows, which is a separate channel (plan decision D5), not a new write.
/// - **Length is deliberately not validated.** Classification looks at the first byte and
///   nothing else, exactly as the reader's dispatch does. A truncated or corrupt blob lands in
///   the bucket that byte names — the same bucket the reader's own dispatch would send it to,
///   which is the answer a census is being asked for ("what will the reader do with these
///   bytes"), not a claim that the bytes are a well-formed sealed box.
///
/// `nonisolated` (overriding this module's MainActor default isolation) and `Sendable`: a pure
/// byte-inspection value type, called synchronously from the sealed store's nonisolated
/// `NSManagedObjectContext.performAndWait` scan, exactly like ``ColumnCrypto`` itself.
public nonisolated enum ColumnCryptoStoredFormat: String, Sendable, Hashable, CaseIterable {
    /// First byte is ``ColumnCrypto/deviceBoundFormatVersionV3`` (`0x03`): the current
    /// device-bound format (purpose ‖ binding as AAD). **Upper bound** — see the type's note on
    /// the 1-in-256 nonce collision.
    case v3Marked
    /// First byte is ``ColumnCrypto/deviceBoundFormatVersionV2`` (`0x02`): the pre-purpose
    /// device-bound format (binding-only AAD). **Upper bound**, same caveat.
    case v2Marked
    /// First byte is neither marker: a bare `combined` blob with no version prefix and no AAD.
    /// **Exact** — this is the definitely-legacy bucket.
    case unprefixed
    /// The column holds no bytes: `nil` (never sealed) or a zero-length `Data`. Not a format at
    /// all, and counted separately so an empty column can never be mistaken for a legacy row.
    case empty

    /// Classifies a stored blob from its bytes alone. Never decrypts, never derives a key, never
    /// touches the keychain, and never allocates a copy of the blob — it reads `data.first`.
    ///
    /// - Parameter data: The raw bytes of one sealed column, or `nil` when the attribute is NULL.
    /// - Returns: The bucket the shipping reader's dispatch would put these bytes in.
    public static func classify(_ data: Data?) -> ColumnCryptoStoredFormat {
        guard let marker = data?.first else { return .empty }
        switch marker {
        case ColumnCrypto.deviceBoundFormatVersionV3:
            return .v3Marked
        case ColumnCrypto.deviceBoundFormatVersionV2:
            return .v2Marked
        default:
            return .unprefixed
        }
    }

    /// The marker byte that produces this bucket, or `nil` for ``empty`` (no bytes) and
    /// ``unprefixed`` (defined by the *absence* of a recognized marker, not by any one value).
    ///
    /// Public so fixtures and diagnostics can build or recognize a marked blob without
    /// re-spelling `0x03`/`0x02`, which would fork the format constants this type exists to
    /// centralize.
    public var markerByte: UInt8? {
        switch self {
        case .v3Marked:
            return ColumnCrypto.deviceBoundFormatVersionV3
        case .v2Marked:
            return ColumnCrypto.deviceBoundFormatVersionV2
        case .unprefixed, .empty:
            return nil
        }
    }

    /// `true` only for ``unprefixed`` — the bucket whose count is exact. Read this as "counting
    /// these rows cannot over-report legacy".
    public var isDefinitelyLegacy: Bool { self == .unprefixed }

    /// `true` for the two marked buckets, whose counts are upper bounds because a legacy blob's
    /// random first nonce byte collides with a marker ~0.39% of the time per marker.
    public var isMarkerAmbiguous: Bool { self == .v3Marked || self == .v2Marked }
}
