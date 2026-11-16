//
//  RecoveryEscrowRecord.swift
//  CloudKitSync
//
//  The recovery-escrow transport DTO (G9-2): one sealed-backup escrow private key, sealed with
//  HPKE to the recovery code's public key, as `CloudKitDataService` reads and writes it. Opaque
//  bytes plus public metadata, like `SealedBackupRecord`: the sealing, the code and every key stay
//  app-side (FernletCrypto's `RecoveryEscrowSeal`), so nothing here can open one.
//

import CryptoKit
import Foundation

/// One escrow private key sealed to a recovery public key, as stored in the `RecoveryEscrowRecord`
/// CloudKit record type in the private database.
///
/// **One record per (recovery key, escrow key)**, named
/// `recovery-escrow.<sha256hex(recoveryPublicKey)>.<hex(escrowPublicKeyHash)>`, so a second phone
/// sealing the same escrow key to the same recovery key overwrites an identical-meaning record,
/// and records for an old recovery key are found by name prefix and deleted when a new code is made
/// ("Make a new code" revokes the old one the moment the delete syncs).
///
/// Every record carries the recovery PUBLIC key, which is how a phone that later mints or adopts an
/// escrow key learns what to seal it to without the code, and ``codeMadeAt``, the date Privacy &
/// data shows ("Made on 15 Nov"). Nothing here is secret on its own: opening ``ciphertext`` needs
/// the recovery private key, which only the 12 words derive.
public struct RecoveryEscrowRecord: Equatable, Sendable {
    /// The record format this build writes and the only one it reads.
    public static let currentFormatVersion = 1

    /// The recovery code's raw X25519 public key (32 bytes).
    public var recoveryPublicKey: Data
    /// SHA-256 of the sealed escrow key's raw public key (32 bytes): the HPKE authenticated data.
    public var escrowPublicKeyHash: Data
    /// The HPKE encapsulated key (32 bytes).
    public var encapsulatedKey: Data
    /// The HPKE ciphertext and tag of the escrow private key.
    public var ciphertext: Data
    /// When the recovery code this record belongs to was made (the same on every record of a code).
    public var codeMadeAt: Date
    /// The record format, ``currentFormatVersion``.
    public var formatVersion: Int

    /// A record from its parts.
    public init(
        recoveryPublicKey: Data,
        escrowPublicKeyHash: Data,
        encapsulatedKey: Data,
        ciphertext: Data,
        codeMadeAt: Date,
        formatVersion: Int = RecoveryEscrowRecord.currentFormatVersion
    ) {
        self.recoveryPublicKey = recoveryPublicKey
        self.escrowPublicKeyHash = escrowPublicKeyHash
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
        self.codeMadeAt = codeMadeAt
        self.formatVersion = formatVersion
    }

    /// The deterministic record name prefix of every record sealed to `recoveryPublicKey`.
    ///
    /// - Parameter recoveryPublicKey: The recovery code's raw public key.
    /// - Returns: `recovery-escrow.<64 hex>.`
    public static func recordNamePrefix(recoveryPublicKey: Data) -> String {
        "\(recordNameRoot)\(hex(Data(SHA256.hash(data: recoveryPublicKey))))."
    }

    /// The record's deterministic name.
    public var recordName: String {
        Self.recordNamePrefix(recoveryPublicKey: recoveryPublicKey) + Self.hex(escrowPublicKeyHash)
    }

    /// The root every recovery-escrow record name starts with.
    public static let recordNameRoot = "recovery-escrow."

    /// Lowercase hex of `data`.
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
