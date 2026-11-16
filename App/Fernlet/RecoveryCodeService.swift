// RecoveryCodeService.swift
// Fernlet
//
// The recovery code for sealed backups (G9-2, plan `Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md`
// Part 2): making a code, keeping its sealed escrow keys current, recovering backups with it, checking
// it, and deleting its records. The crypto is FernletCrypto's (`RecoveryCode`, `RecoveryEscrowSeal`);
// the records are CloudKitSync's opaque `RecoveryEscrowRecord`; the escrow private keys never leave
// `SealedBackupEscrowKey`, which seals them and stores the recovered ones.

import CloudKitSync
import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import ProximityKit

/// The CloudKit half of the recovery code: ``CloudKitDataService``'s recovery-escrow calls, behind a
/// seam so ``RecoveryCodeService`` is testable without iCloud.
@MainActor
protocol RecoveryEscrowStoring {
    /// Saves sealed escrow keys (one record each).
    func saveRecoveryEscrowRecords(_ records: [RecoveryEscrowRecord]) async throws
    /// Every recovery-escrow record in iCloud.
    func recoveryEscrowRecords() async throws -> [RecoveryEscrowRecord]
    /// Deletes every record not sealed to `keeping` (all of them for nil); returns how many.
    func deleteRecoveryEscrowRecords(keeping: Data?) async throws -> Int
}

extension CloudKitDataService: RecoveryEscrowStoring {}

/// Makes, keeps current, checks and uses the recovery code that reopens the sealed backups on a phone
/// that lost iCloud Keychain.
///
/// **The model** (a recovery key pair, not a wrapped copy): the code's 12 words derive an X25519 key
/// pair; every escrow key is sealed to the public half and stored in iCloud as a
/// `RecoveryEscrowRecord` carrying that public key. A phone that later mints or adopts another escrow
/// key seals it too, from the stored public key, with no code (``sealNewEscrowKeys()``, run at every
/// launch's escrow reconcile). Typing the code derives the private half and opens the records
/// (``recover(with:)``).
///
/// **The current code** is the set of records sharing one recovery public key; when two sets exist
/// (a "Make a new code" whose delete has not landed, or two phones making codes at once) the newest
/// `codeMadeAt` wins, and ``sealNewEscrowKeys()`` deletes the others, finishing the revoke.
///
/// **Refused in a duress session** (every call throws ``RecoveryCodeFailure/refusedInDuress``): the
/// decoy must not reveal, make or use the owner's code. The code itself is never stored; the screens
/// that show it ask for a fresh passcode or Face ID first and are capture-protected.
@MainActor
final class RecoveryCodeService {
    /// The record store (production: ``CloudKitDataService``).
    private let cloud: any RecoveryEscrowStoring
    /// Builds the identity whose escrow keys are sealed and restored.
    private let identityFactory: @MainActor () -> IdentityService
    /// Whether a duress session is active.
    private let duressActive: () -> Bool
    /// The clock that dates a new code.
    private let now: () -> Date
    /// Whether any encrypted backup is switched on: a code made then may mint the escrow key the
    /// backup's first upload would mint anyway.
    private let anyBackupEnabled: () -> Bool

    /// A service over `cloud` and the identity `identityFactory` builds.
    ///
    /// - Parameters:
    ///   - cloud: Where the records live.
    ///   - identityFactory: Builds the identity; nil for Fernlet's (``IdentityService/fernletApp(keychainService:)``).
    ///   - duressActive: Whether a duress session is active; every call refuses while it is.
    ///   - anyBackupEnabled: Whether any encrypted backup is on (see ``makeNewCode()``).
    ///   - now: The clock.
    init(
        cloud: any RecoveryEscrowStoring,
        identityFactory: (@MainActor () -> IdentityService)? = nil,
        duressActive: @escaping () -> Bool,
        anyBackupEnabled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init
    ) {
        self.cloud = cloud
        self.identityFactory = identityFactory ?? { IdentityService.fernletApp() }
        self.duressActive = duressActive
        self.anyBackupEnabled = anyBackupEnabled
        self.now = now
    }

    /// The current code's state, read from iCloud.
    ///
    /// - Returns: ``RecoveryCodeStatus/notSetUp`` with no records, else the date the code was made.
    func status() async throws -> RecoveryCodeStatus {
        try refuseInDuress()
        guard let current = Self.currentSet(of: try await cloud.recoveryEscrowRecords()) else { return .notSetUp }
        return .madeOn(current.madeAt)
    }

    /// Makes a new code: fresh entropy, every escrow key on this phone sealed to its public key, the
    /// records saved, then every older code's records deleted (the revoke).
    ///
    /// With a backup switched on but its first upload not yet run (the Private tab not opened since),
    /// there is no escrow key yet: the seal path mints it now, exactly as that upload would
    /// (``IdentityService/provisionBackupEscrowKeyForSealing()``, device-only until a later launch).
    ///
    /// - Returns: The new code, to show once; the caller drops it when the screen closes.
    /// - Throws: ``RecoveryCodeFailure/noBackupKey`` when this phone holds no escrow key (no encrypted
    ///   backup was turned on), ``RecoveryCodeFailure/refusedInDuress``, or the cloud's error. A failed
    ///   revoke is not thrown: the new code works, and the next launch's ``sealNewEscrowKeys()`` deletes
    ///   the old records.
    func makeNewCode() async throws -> RecoveryCode {
        try refuseInDuress()
        let identity = try provisionedIdentity()
        if !identity.holdsEscrowKeyForRecovery, anyBackupEnabled() {
            identity.provisionBackupEscrowKeyForSealing()
        }
        guard identity.holdsEscrowKeyForRecovery else { throw RecoveryCodeFailure.noBackupKey }
        let code = try RecoveryCode.generate()
        let publicKey = try code.recoveryPublicKey()
        let sealed = try identity.sealEscrowKeysForRecovery(to: publicKey, skipping: [])
        guard !sealed.isEmpty else { throw RecoveryCodeFailure.noBackupKey }
        let madeAt = now()
        try await cloud.saveRecoveryEscrowRecords(sealed.map { Self.record($0, recoveryPublicKey: publicKey, madeAt: madeAt) })
        do {
            _ = try await cloud.deleteRecoveryEscrowRecords(keeping: publicKey)
        } catch {
            FernletAuditLog.log("recoveryCode.revokeDeferred")
        }
        FernletAuditLog.log("recoveryCode.made", context: ["sealedKeys": String(sealed.count)])
        return code
    }

    /// Keeps the current code current without it: seals every escrow key this phone holds that has
    /// no record yet to the stored recovery public key, and deletes any older code's records.
    ///
    /// - Returns: How many escrow keys were newly sealed (0 with no code, or nothing new).
    @discardableResult
    func sealNewEscrowKeys() async throws -> Int {
        try refuseInDuress()
        let records = try await cloud.recoveryEscrowRecords()
        guard let current = Self.currentSet(of: records) else { return 0 }
        if records.contains(where: { $0.recoveryPublicKey != current.publicKey }) {
            _ = try await cloud.deleteRecoveryEscrowRecords(keeping: current.publicKey)
        }
        let identity = try provisionedIdentity()
        let sealed = try identity.sealEscrowKeysForRecovery(to: current.publicKey, skipping: current.escrowHashes)
        guard !sealed.isEmpty else { return 0 }
        try await cloud.saveRecoveryEscrowRecords(sealed.map {
            Self.record($0, recoveryPublicKey: current.publicKey, madeAt: current.madeAt)
        })
        FernletAuditLog.log("recoveryCode.sealedNewEscrowKeys", context: ["count": String(sealed.count)])
        return sealed.count
    }

    /// Recovers with a typed code: opens every record sealed to its public key and stores the escrow
    /// keys on this phone as device-only rows (the normal WS-2 promote path takes it from there). The
    /// caller then retries the restore.
    ///
    /// - Parameter code: The typed code (its checksum already passed).
    /// - Returns: How many escrow keys are now on this phone.
    /// - Throws: ``RecoveryCodeFailure/noCodeSetUp`` when iCloud holds no records,
    ///   ``RecoveryCodeFailure/codeDoesNotMatch`` when none is sealed to this code (an old or wrong
    ///   code), ``RecoveryCodeFailure/refusedInDuress``, or the cloud's error.
    func recover(with code: RecoveryCode) async throws -> Int {
        try refuseInDuress()
        let records = try await cloud.recoveryEscrowRecords()
        guard !records.isEmpty else { throw RecoveryCodeFailure.noCodeSetUp }
        let privateKey = try code.recoveryPrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let matching = records.filter { $0.recoveryPublicKey == publicKey }
        guard !matching.isEmpty else { throw RecoveryCodeFailure.codeDoesNotMatch }
        var keys: [Curve25519.KeyAgreement.PrivateKey] = []
        for record in matching {  // R2: bounded by the fetched records.
            do {
                keys.append(try RecoveryEscrowSeal.open(Self.sealedKey(record), with: privateKey))
            } catch {
                FernletAuditLog.log("recoveryCode.recordUnopenable")
            }
        }
        guard !keys.isEmpty else { throw RecoveryCodeFailure.codeDoesNotMatch }
        let stored = try provisionedIdentity().storeRecoveredEscrowKeys(keys)
        FernletAuditLog.log("recoveryCode.recovered", context: ["keys": String(stored)])
        return stored
    }

    /// "Check my code": whether a typed code is the current one. Reads only; stores and restores
    /// nothing.
    ///
    /// - Parameter code: The typed code (its checksum already passed).
    /// - Returns: ``RecoveryCodeCheck/matches``, ``RecoveryCodeCheck/doesNotMatch`` (an old or
    ///   mistyped code) or ``RecoveryCodeCheck/noCodeSetUp``.
    func check(_ code: RecoveryCode) async throws -> RecoveryCodeCheck {
        try refuseInDuress()
        guard let current = Self.currentSet(of: try await cloud.recoveryEscrowRecords()) else { return .noCodeSetUp }
        return try code.recoveryPublicKey() == current.publicKey ? .matches : .doesNotMatch
    }

    // MARK: Helpers

    /// The current code's records: the newest `codeMadeAt`, ties broken by the smaller public key.
    struct CurrentSet: Equatable {
        /// The recovery public key.
        let publicKey: Data
        /// When that code was made.
        let madeAt: Date
        /// The escrow public-key hashes already sealed to it.
        let escrowHashes: Set<Data>
    }

    /// The current code among `records`, or nil for none.
    static func currentSet(of records: [RecoveryEscrowRecord]) -> CurrentSet? {
        let newest = records.max { lhs, rhs in
            if lhs.codeMadeAt != rhs.codeMadeAt { return lhs.codeMadeAt < rhs.codeMadeAt }
            // Ordered so the SMALLER key is the max on a tie: every phone picks the same set.
            return rhs.recoveryPublicKey.lexicographicallyPrecedes(lhs.recoveryPublicKey)
        }
        guard let newest else { return nil }
        let members = records.filter { $0.recoveryPublicKey == newest.recoveryPublicKey }
        return CurrentSet(publicKey: newest.recoveryPublicKey, madeAt: newest.codeMadeAt,
                          escrowHashes: Set(members.map(\.escrowPublicKeyHash)))
    }

    private func refuseInDuress() throws {
        guard !duressActive() else {
            FernletAuditLog.log("recoveryCode.refusedInDuress")
            throw RecoveryCodeFailure.refusedInDuress
        }
    }

    private func provisionedIdentity() throws -> IdentityService {
        let identity = identityFactory()
        try identity.ensureProvisioned()
        return identity
    }

    private static func record(_ sealed: RecoveryEscrowSealedKey, recoveryPublicKey: Data, madeAt: Date) -> RecoveryEscrowRecord {
        RecoveryEscrowRecord(recoveryPublicKey: recoveryPublicKey, escrowPublicKeyHash: sealed.escrowPublicKeyHash,
                             encapsulatedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext, codeMadeAt: madeAt)
    }

    private static func sealedKey(_ record: RecoveryEscrowRecord) -> RecoveryEscrowSealedKey {
        RecoveryEscrowSealedKey(escrowPublicKeyHash: record.escrowPublicKeyHash,
                                encapsulatedKey: record.encapsulatedKey, ciphertext: record.ciphertext)
    }
}

/// Whether a recovery code exists, and when it was made.
enum RecoveryCodeStatus: Equatable {
    /// No code was made for this iCloud account.
    case notSetUp
    /// The current code was made on this date.
    case madeOn(Date)
}

/// What "Check my code" found.
enum RecoveryCodeCheck: Equatable {
    /// The typed code is the current one and opens the backups.
    case matches
    /// The typed code is real but not the current one (an old or mistyped code).
    case doesNotMatch
    /// No code was made for this iCloud account.
    case noCodeSetUp
}

/// Why a recovery-code action was refused.
enum RecoveryCodeFailure: Error, Equatable {
    /// This phone holds no backup escrow key: no encrypted backup was ever turned on.
    case noBackupKey
    /// iCloud holds no recovery code's records.
    case noCodeSetUp
    /// The typed code opens none of the records: an old code, or another account's.
    case codeDoesNotMatch
    /// A duress session is active.
    case refusedInDuress
}
