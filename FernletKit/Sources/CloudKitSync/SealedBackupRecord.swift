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

public enum SealedBackupPayloadType: String, Codable, CaseIterable {
    case sensitiveNotes
    case periodData
}

public struct SealedBackupRecord: Equatable {
    public var payloadType: SealedBackupPayloadType
    public var signingPublicKey: Data
    public var keyAgreementPublicKey: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
    public var updatedAt: Date
    /// Position of this record within a payload's chunk set. A non-chunked payload (sensitive
    /// notes, or a short period history) is a single record at `chunkIndex == 0, chunkCount == 1`.
    public var chunkIndex: Int
    public var chunkCount: Int

    public init(
        payloadType: SealedBackupPayloadType,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        updatedAt: Date,
        chunkIndex: Int = 0,
        chunkCount: Int = 1
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
    }
}

public enum SealedBackupError: Error, Equatable {
    case keyAgreementIdentityMismatch
    case malformedRecord
}
