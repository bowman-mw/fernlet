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

/// Which sealed dataset a backup record carries: sensitive notes or period data.
///
/// The raw value keys the deterministic CloudKit record name (`sealed-backup.<type>`), so each
/// payload type has exactly one backup — a head record plus optional chunks — per account.
public enum SealedBackupPayloadType: String, Codable, CaseIterable {
    case sensitiveNotes
    case periodData
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
        generation: Int64
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
