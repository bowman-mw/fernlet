// FeatureCanonicalBytes.swift
// FernletSocial/Wire
//
// The canonical signing bytes of Fernlet's mesh features, moved from ProximityKit's canonical serializer
// (`CanonicalSignatureSerializer.swift`) with no byte change: each feature's domain tag and its
// `canonicalBytes(for:)` overload, under the same spelling, written with ProximityKit's public
// `CanonicalByteWriter`, whose encodings the engine's goldens freeze. The activity feature's three
// (Phase 6: the descriptor its params hash is taken over, the join token and the roster snapshot) came
// with the activity manager and its payloads in ProximityKit plan step A0.5.8; the moderation report
// row's (Phase 3b) with the report relay in A0.5.7. The serializer keeps no feature domain: every one
// it still writes is its host namespace's.
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

// Group Activities (Phase 6). Distinct tags so an activity descriptor hash, a join token, and a roster
// snapshot can never cross-validate one another (or any other signed type).
private nonisolated let canonicalActivityDescriptorDomain = FernletCryptoPurpose.Signature.activityDescriptorV2.data
private nonisolated let canonicalActivityJoinTokenDomain = FernletCryptoPurpose.Signature.activityJoinTokenV2.data
private nonisolated let canonicalActivityRosterSnapshotDomain = FernletCryptoPurpose.Signature.activityRosterSnapshotV2.data
// Moderation report row (Phase 3b). Distinct tag so a report signature can never cross-validate any
// other signed type.
private nonisolated let canonicalModerationReportDomain = FernletCryptoPurpose.Signature.moderationReportV2.data

// MARK: - Group Activities (Phase 6)

// All three include the SIGNED `schemaVersion` (where present), so `verify` uses a SINGLE encoder gated
// on the version — no permanent dual-verify (contrast ProximityKit's `MeshAdmissionToken`, which verifies
// under two encodings). Because these types are new (day one), there is no legacy encoder for them and
// never will be.

/// Canonical bytes an `ActivityDescriptor` is hashed over to form `activityParamsHash` (SHA-256). The
/// descriptor is not itself signed; this hash is what the signed token/snapshot bind, so its byte
/// layout must be as stable as any signing input.
public nonisolated func canonicalBytes(for descriptor: ActivityDescriptor) -> Data {
    var writer = CanonicalByteWriter()
    writer.appendLengthPrefixed(canonicalActivityDescriptorDomain)
    writer.appendUUID(descriptor.activityID)
    writer.appendString(descriptor.hostFingerprint)
    writer.appendLengthPrefixed(descriptor.hostSigningPublicKey)
    writer.appendString(descriptor.title)
    writer.appendString(descriptor.activityTypeToken)
    writer.appendOptional(descriptor.coarseLocation)
    writer.appendDate(descriptor.createdAt)
    writer.appendDate(descriptor.expiresAt)
    return writer.bytes
}

/// Canonical signing bytes for an `ActivityJoinToken`. The `hostSignature` field is excluded (it is the
/// output of signing these bytes).
public nonisolated func canonicalBytes(for token: ActivityJoinToken) -> Data {
    var writer = CanonicalByteWriter()
    writer.appendLengthPrefixed(canonicalActivityJoinTokenDomain)
    writer.appendInt64(Int64(token.schemaVersion))
    writer.appendUUID(token.activityID)
    writer.appendLengthPrefixed(token.activityParamsHash)
    writer.appendString(token.joinerFingerprint)
    writer.appendLengthPrefixed(token.joinerSigningPublicKey)
    writer.appendString(token.hostFingerprint)
    writer.appendLengthPrefixed(token.hostSigningPublicKey)
    writer.appendDate(token.grantedAt)
    writer.appendDate(token.expiresAt)
    writer.appendInt64(Int64(token.rosterVersionAtGrant))
    // hostSignature: deliberately excluded.
    return writer.bytes
}

/// Canonical signing bytes for an `ActivityRosterSnapshot`. The `hostSignature` field is excluded. The
/// participant array is length-prefixed and serialized in array order (the host's authored order IS the
/// canonical order), so the same roster always produces the same bytes.
public nonisolated func canonicalBytes(for snapshot: ActivityRosterSnapshot) -> Data {
    var writer = CanonicalByteWriter()
    writer.appendLengthPrefixed(canonicalActivityRosterSnapshotDomain)
    writer.appendInt64(Int64(snapshot.schemaVersion))
    writer.appendUUID(snapshot.activityID)
    writer.appendInt64(Int64(snapshot.version))
    writer.appendUInt64(UInt64(snapshot.participants.count))
    for participant in snapshot.participants {
        writer.appendString(participant.fingerprint)
        writer.appendString(participant.displayName)
        writer.appendLengthPrefixed(participant.signingPublicKey)
        writer.appendLengthPrefixed(participant.keyAgreementPublicKey)
        writer.appendDate(participant.joinedAt)
    }
    writer.appendDate(snapshot.issuedAt)
    writer.appendLengthPrefixed(snapshot.hostSigningPublicKey)
    // hostSignature: deliberately excluded.
    return writer.bytes
}

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
