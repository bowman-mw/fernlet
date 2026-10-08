// FeatureCanonicalBytes.swift
// FernletSocial/Wire
//
// The canonical signing bytes of Fernlet's mesh features, moved from ProximityKit's canonical serializer
// (`CanonicalSignatureSerializer.swift`) in ProximityKit plan step A0.5.7 with no byte change: each
// feature's domain tag and its `canonicalBytes(for:)` overload, under the same spelling, written with
// ProximityKit's public `CanonicalByteWriter`, whose encodings the engine's goldens freeze. Today the
// moderation report row's (Phase 3b); the activity feature's three domains and overloads stay in the
// serializer until the activities leave ProximityKit (plan step A0.5.8).
//
// This is signing INPUT only, as the serializer's is: never the wire format, never persisted, never
// transmitted. Each overload is told apart from the serializer's by its parameter type alone.

import Foundation
import FernletCrypto
import FernletDomainModel
import ProximityKit

// Every declaration in this file is `nonisolated`, as in the serializer it came from: FernletSocial sets
// `.defaultIsolation(MainActor.self)`, which would otherwise MainActor-isolate this pure signing-byte
// serializer, and the bytes are derived from value-type fields with no actor state, so signing and
// signature verification must be runnable from any isolation domain.

// MARK: - Domain tags

// Moderation report row (Phase 3b). Distinct tag so a report signature can never cross-validate any
// other signed type.
private nonisolated let canonicalModerationReportDomain = FernletCryptoPurpose.Signature.moderationReportV2.data

// MARK: - Moderation report (Phase 3b)

/// Canonical signing bytes for a `ModerationLedgerEntry` — the deterministic bytes a reporter signs and
/// a receiver re-derives to verify. Both ends produce identical bytes for the same row. `createdAt` is
/// bound at whole-second resolution (a hostile future date is part of the signature; the receiver may
/// then clamp the STORED createdAt for decay without touching verification). Length-prefixing makes the
/// encoding injective — no value can shift a field boundary — and `appendDate` saturates instead of
/// trapping on an out-of-range wire date. There is no legacy encoder: this row type never signed before.
public nonisolated func canonicalBytes(for entry: ModerationLedgerEntry) -> Data {
    var writer = CanonicalByteWriter()
    writer.appendLengthPrefixed(canonicalModerationReportDomain)
    writer.appendString(entry.kind.rawValue)
    writer.appendLengthPrefixed(entry.reporterSigningPublicKey)
    writer.appendLengthPrefixed(entry.subjectSigningPublicKey)
    writer.appendUUID(entry.itemID)
    writer.appendLengthPrefixed(entry.contentHash)
    writer.appendString(entry.reasonToken)
    writer.appendUInt64(entry.reporterSeq)
    writer.appendDate(entry.createdAt)
    // signature: lives on `SignedModerationReport`, not the entry — nothing to exclude here.
    return writer.bytes
}
