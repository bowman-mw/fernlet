//
//  SealedBackupRecord.swift
//  CloudKitSync
//
//  The sealed-backup transport DTOs: the opaque encrypted record shape that
//  `CloudKitDataService` reads/writes to CloudKit, plus its payload-type and error
//  enums. These carry only ciphertext + crypto metadata — never any plaintext or
//  sealed-store type — so they live in the synced-blob module alongside the service
//  that serializes them. The sealing/opening (`SealedBackupCrypto`) and the
//  `SealedBackupService` that drives reconcile/restore remain in the app, since they
//  depend on the on-device identity service.
//

import Foundation

/// Which sealed dataset a backup record carries: sensitive notes, period data, journal narratives,
/// or intimacy logs.
///
/// The raw value keys the deterministic CloudKit record name (`sealed-backup.<type>`), so each
/// payload type has exactly one backup — a head record plus optional chunks — per account. It is
/// ALSO bound into the GCM additional-authenticated-data (`SealedBackupCrypto.authenticatedData`),
/// which is what stops a chunk being replayed as a different payload.
///
/// - Important: These raw values are **at-rest format**. Renaming one orphans every backup already
///   in users' CloudKit databases (the record name no longer resolves) *and* breaks the AAD of any
///   record that is still fetched, so they must never change once shipped.
///
/// - Note: The Worry Box is deliberately absent. "Let it go" notes are device-only by design (see
///   `PrivatePersistenceController.makeWorryNarrativeEntity`), so they are not backed up and do not
///   survive a device reset — an accepted property, not an oversight.
public enum SealedBackupPayloadType: String, Codable, CaseIterable {
    case sensitiveNotes
    case periodData
    /// Sealed journal narratives (`JournalNarrative` rows). Added 2026-08-10 so journal text survives
    /// a fresh install — the precondition for hard-binding the lock content key.
    case journalNarratives
    /// Sealed intimacy logs (`IntimacyLog` rows). Added 2026-08-10; this **reverses** the earlier
    /// "intimacy is not part of any sealed backup" decision (see `Docs/Verifiability.md` §6.1).
    case intimacyLogs
}

/// Opaque encrypted envelope for one chunk of a sealed backup, as stored in CloudKit.
///
/// Carries only ciphertext plus crypto metadata (public keys, nonce, tag, chunk position) —
/// never plaintext or any sealed-store type — which is why this transport DTO can live in the
/// walled sync module. ``CloudKitDataService`` serializes it to/from the `SealedBackupRecord`
/// CloudKit record type (ciphertext travels as a `CKAsset`); the sealing/opening crypto and the
/// reconcile/restore service stay app-side with the identity service. Payloads too large for
/// one record are split into a chunk set whose head (`chunkIndex == 0`) carries the
/// authoritative `chunkCount`; records written before chunking existed decode as chunk 0 of 1.
///
/// ``formatVersion`` + ``keySalt`` are the at-rest **record format** discriminator: a record written
/// before they existed decodes as version 1 (legacy static escrow derivation, empty salt), while every
/// new write is version 2 (per-generation salted derivation). Both open through the same crypto on the
/// same identity, so v1 and v2 records coexist in one container with no migration.
public struct SealedBackupRecord: Equatable {
    public var payloadType: SealedBackupPayloadType
    /// The owner's signing public key, carried as provenance for the app-side restore checks.
    public var signingPublicKey: Data
    /// The owner's backup-ESCROW public key (X25519), used purely as a device-stable identity tag so a
    /// restore can confirm "this backup is mine" before attempting decryption. It is NOT the proximity
    /// key-agreement key (which is per-device); the escrow key syncs via iCloud Keychain, so this value
    /// matches across a user's devices and permits cross-device restore. (Field name kept for the
    /// existing CloudKit schema mapping.)
    public var keyAgreementPublicKey: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
    public var updatedAt: Date
    /// Position of this record within a payload's chunk set. A non-chunked payload (sensitive
    /// notes, or a short period history) is a single record at `chunkIndex == 0, chunkCount == 1`.
    public var chunkIndex: Int
    public var chunkCount: Int
    /// Monotonic per-payload-type write counter, minted once per backup generation and shared by
    /// every chunk of that generation.
    ///
    /// **This is the rollback defense** (code review finding 14, fixed 2026-08-09). It is bound into
    /// the GCM additional-authenticated-data along with `updatedAt`, so it cannot be edited without
    /// breaking authentication — an attacker who can write to the CloudKit container can still
    /// *substitute* a whole older-but-validly-sealed generation, but the app-side
    /// `SealedBackupGenerationStore` remembers the highest generation this device has written or
    /// accepted and refuses anything older on restore.
    ///
    /// Counters are device-local, so two devices that both write can mint the same number. That is
    /// fine: the guarantee is "never accept older than what I have already seen", which holds
    /// regardless of which device minted a given value.
    public var generation: Int64
    /// Which at-rest **record format** this record was sealed in — the discriminator that lets v1 and v2
    /// records coexist in one container with no migration.
    ///
    /// `1` (the default, and what a record written before this field existed decodes as) means the
    /// legacy static key derivation: empty HKDF salt, info `com.fernlet.sealed-backup`. `2` means the
    /// per-generation-salt derivation: HKDF salted with ``keySalt`` under info
    /// `com.fernlet.sealed-backup.v2`. All new writes are v2; v1 is read-compat only.
    ///
    /// This is deliberately an **explicit** discriminator rather than inferring the format from
    /// "is `keySalt` empty" — an inference would silently downgrade a v2 record whose salt field was
    /// dropped in transit, whereas the explicit version makes that case fail closed on decode.
    ///
    /// Note this is orthogonal to the `fernlet.sealed-backup.aad.v2` tag inside the GCM
    /// additional-authenticated-data, which versions the **AAD byte layout** and is unchanged here.
    public var formatVersion: Int
    /// The 32 random bytes mixed into the escrow HKDF for this backup **generation** (empty for v1).
    ///
    /// Minted once per generation beside the ``generation`` counter and stamped on **every** chunk of
    /// that generation, so each record is self-describing and `open()` never depends on fetch order (the
    /// head chunk is written last as the commit marker, so "store the salt in the head" would not work).
    ///
    /// It is a plaintext CKRecord field, like ``nonce``, and must be: it derives the key that opens the
    /// ciphertext, so a salt hidden inside the payload would be unrecoverable. It is deliberately **not**
    /// bound into the AAD — a tampered salt already yields the wrong key and fails AES-GCM open, so
    /// binding it would be redundant and would needlessly fork the pinned AAD layout.
    ///
    /// The security win is blast radius: one escrow-key compromise no longer derives a single key that
    /// opens every past and future backup, only one key per generation.
    public var keySalt: Data

    public init(
        payloadType: SealedBackupPayloadType,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        updatedAt: Date,
        chunkIndex: Int = 0,
        chunkCount: Int = 1,
        generation: Int64,
        formatVersion: Int = 1,
        keySalt: Data = Data()
    ) {
        self.payloadType = payloadType
        self.signingPublicKey = signingPublicKey
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.updatedAt = updatedAt
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.generation = generation
        self.formatVersion = formatVersion
        self.keySalt = keySalt
    }
}

/// Failures raised while decoding or reassembling a sealed backup.
///
/// `malformedRecord` covers both an undecodable CloudKit record and an incomplete or
/// inconsistent chunk set (restore is all-or-nothing, so a corrupt history is never
/// reassembled); `keyAgreementIdentityMismatch` is thrown by the app-side restore service when
/// a fetched backup's escrow identity does not match the current user's keys;
/// `staleGeneration` is the rollback rejection.
public enum SealedBackupError: Error, Equatable {
    case keyAgreementIdentityMismatch
    case malformedRecord
    /// The fetched backup authenticates correctly but its generation predates one this device has
    /// already written or restored — i.e. someone substituted an older, validly sealed backup.
    ///
    /// Carries both values so the UI can be specific instead of saying "corrupt". This is never a
    /// normal outcome: a legitimate backup only ever moves forward.
    case staleGeneration(found: Int64, lastSeen: Int64)
}
