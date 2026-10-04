// SealedBackupEscrowKey.swift
// Fernlet
//
// The sealed-backup escrow key: the X25519 key every Sealed backup and every own-photo backup is
// sealed under, kept in iCloud Keychain beside the device identity's rows, under the identity's
// keychain service, and the identity's provisioning participant that accounts for it. Every escrow
// row lives at a CONTENT-ADDRESSED account (`backupEscrowPrivateKey.k.` + the SHA-256 of the key's
// own public key), so two DIFFERENT escrow keys land on DIFFERENT keychain slots and COEXIST under
// iCloud Keychain rather than resolving by "newest-modification-date wins" on one shared slot. That
// eliminates the residual where a divergent (newer) key silently overwrote the genuine (older) escrow
// key cross-device, permanently stranding the origin device's backups. Divergence now becomes an
// additive, non-silent `.conflict` (≥2 coexisting keys), never a destructive overwrite. The legacy
// fixed account "backupEscrowPrivateKey" is still READ for back-compat (pre-content-addressing
// devices) but never written to by this build.

import CryptoKit
import FernletConnections
import FernletCrypto
import FernletFoundation
import Foundation
import ProximityKit
import Security

// MARK: - Keychain key identifiers

/// The fixed keychain account name of the legacy escrow row (content-addressed escrow slots are
/// derived separately from the escrow key's own public key, ``SealedBackupEscrowKey/escrowKeychainAccount(forPublicKey:)``).
///
/// The `backupEscrowPrivateKey` account is legacy: read for back-compat, never written by this
/// build.
private enum IdentityKeychainKey: String {
    case backupEscrowPrivateKey     = "backupEscrowPrivateKey"
}

// MARK: - The escrow key

/// Fernlet's sealed-backup escrow key, and the device identity's provisioning participant that
/// accounts for it (ProximityKit's `IdentityProvisioningParticipant`).
///
/// **One per identity, on every identity Fernlet builds.** `IdentityService.fernletApp(keychainService:)`
/// builds each of the app's identities with a fresh one, and `FernletStore`'s
/// `makeProximityIdentity()` answers that factory for the proximity managers, so whichever identity
/// provisions first on a device runs the escrow's provisioning cases.
/// `KeyCustodyBoundaryTests.everyShippingIdentityIsBuiltByItsHostsDoor` holds every shipping
/// construction of an identity to that factory and ProximityKit's host default. The app reaches the
/// escrow through the identity (its `IdentityService` extension below forwards each call here).
///
/// **Provisioning's four cases**, in the order the identity's `ensureProvisioned()` calls this
/// participant:
/// 1. *The device keys are present* (``identityAdoptedDeviceKeys(_:)``): adopt the canonical escrow
///    key already in the keychain, if any, before the identity rewrites its key-agreement row
///    device-only. Never mint.
/// 2. *An escrow key is present and the device keys are not* (``identityWillMintDeviceKeys(_:previousKeyAgreementKey:)``):
///    adopt it once the mint lands; the previous build's key-agreement row is not read.
/// 3. *No escrow key, and a previous build's synced key-agreement key in the row*: promote that key to
///    its own content-addressed synced escrow slot BEFORE the mint overwrites the row, and adopt it
///    once the mint lands. A failed promotion throws `IdentityError.keychainWriteFailed` (audited
///    `identity.escrow.legacyPromoteFailed`), so nothing is minted and the row survives; an
///    unreadable row throws `IdentityError.keychainReadFailed(_:)` from the identity's reader, with
///    nothing written.
/// 4. *Neither*: adopt nothing. The escrow key is deferred to sealed-backup-enable time (WS-1,
///    ``provisionBackupEscrowKeyForSealing(service:)``), so a fresh device never publishes a divergent
///    synchronizable escrow key.
///
/// A mint that fails leaves the adopted key untouched (``identityMintedDeviceKeys(_:)`` is never
/// called for it), and ``identityWiped(_:)`` drops it with the identity's keys.
///
/// **The rows**, all under the identity's keychain service: a minted key at its content-addressed
/// account `AfterFirstUnlockThisDeviceOnly`, never synchronized (WS-2), until a later launch's
/// reconcile publishes it there `kSecAttrAccessibleAfterFirstUnlock` with `synchronizable: true`; a
/// promoted previous-build key the same way, at once; reads enumerate both variants and the legacy
/// fixed account. Every keychain call goes through FernletFoundation's `KeychainItem` and every audit
/// line through `FernletAuditLog`, under the `identity.escrow.*` names. This file is the one shipping
/// file that writes a synchronizable row, which `KeyCustodyBoundaryTests` holds it to.
///
/// Main-actor, like the identity; the pure statics (``escrowKeychainAccount(forPublicKey:)``, the
/// slot prefix and the HKDF derivation) are `nonisolated`.
@MainActor
final class SealedBackupEscrowKey: IdentityProvisioningParticipant {

    /// The adopted (canonical) escrow key, or nil when none is adopted: what the identity's
    /// `localBackupEscrowPublicKey` and sealed-backup keys answer from.
    private var adopted: Curve25519.KeyAgreement.PrivateKey?

    /// The escrow key a mint in progress adopts once the fresh device keys are on disk: set by
    /// ``identityWillMintDeviceKeys(_:previousKeyAgreementKey:)`` (Cases 2 to 4, nil for Case 4) and
    /// consumed by ``identityMintedDeviceKeys(_:)``; a failed mint never consumes it, and the next
    /// will-mint or a wipe replaces it.
    private var pendingAdoption: Curve25519.KeyAgreement.PrivateKey?

    /// A participant holding no escrow key: the next provisioning of its identity decides which.
    init() {}

    // MARK: Provisioning participant

    /// Case 1: the identity adopted the device keys already on this device. Adopts an existing backup
    /// escrow key if one is present (synced preferred). Does NOT mint one here — escrow generation is
    /// deferred to sealed-backup-enable time (WS-1).
    ///
    /// - Parameter identity: The identity that adopted them; its rows' service is the escrow's.
    func identityAdoptedDeviceKeys(_ identity: IdentityService) {
        adopted = loadExistingEscrowKey(service: identity.keychainService)
    }

    /// Cases 2 to 4, before the identity mints fresh device keys over its rows.
    ///
    /// Case 2: Backup escrow key synced from iCloud (new device install, post-migration): adopt it
    /// once the mint lands. With WS-1's deferral the previous "race mints a divergent key" residual is
    /// gone: a fresh device that opens before the escrow key syncs simply has no escrow key (Case 4)
    /// until enable time, and the open/restore path treats absence as "not synced yet" rather than
    /// fabricating a new key.
    ///
    /// Case 3: Legacy synced KA key present (pre-migration second-device path). Promote the old
    /// (already-synced) KA key to backup escrow role before the mint overwrites its row. This reuses an
    /// existing synced key, not a fresh mint, so there is no divergence risk — and it is published at
    /// the key's CONTENT-ADDRESSED account (two devices running Case 3 derive the same account from the
    /// same KA key → same slot, same value → no conflict), never the legacy slot.
    ///
    /// Case 4: No keys at all — the identity mints signing + proximity KA only. The escrow key is
    /// deferred to enable time (WS-1), so a fresh device never publishes a divergent synchronizable
    /// escrow key.
    ///
    /// - Parameters:
    ///   - identity: The identity about to mint.
    ///   - previousKeyAgreementKey: The identity's fail-closed reader of the key-agreement row a
    ///     previous build left, read only when no escrow key is present.
    /// - Throws: `IdentityError.keychainReadFailed(_:)` from the reader when the row is unreadable, and
    ///   `IdentityError.keychainWriteFailed` when the promotion did not land; either way the identity
    ///   mints nothing.
    func identityWillMintDeviceKeys(
        _ identity: IdentityService,
        previousKeyAgreementKey: () throws -> Curve25519.KeyAgreement.PrivateKey?
    ) throws {
        pendingAdoption = nil
        if let loadedEscrow = loadExistingEscrowKey(service: identity.keychainService) {
            pendingAdoption = loadedEscrow
            return
        }
        guard let loadedKA = try previousKeyAgreementKey() else { return }
        try promoteLegacyKeyAgreementKeyToEscrow(loadedKA, service: identity.keychainService)
        pendingAdoption = loadedKA
    }

    /// The fresh device keys are on disk and adopted: adopts the escrow key the mint was waiting for
    /// (Cases 2 and 3), or none (Case 4).
    ///
    /// - Parameter identity: The identity that minted them.
    func identityMintedDeviceKeys(_ identity: IdentityService) {
        adopted = pendingAdoption
        pendingAdoption = nil
    }

    /// The identity swept its rows, the escrow's included: drops the escrow key from memory.
    ///
    /// - Parameter identity: The identity that was wiped.
    func identityWiped(_ identity: IdentityService) {
        adopted = nil
        pendingAdoption = nil
    }

    /// Publishes a legacy already-synced KA key into its content-addressed escrow slot (Case 3).
    /// Throws on a failed write so the caller does not adopt an escrow key that is not on disk —
    /// sealing under a key nothing persisted makes those backups permanently unrecoverable.
    private func promoteLegacyKeyAgreementKeyToEscrow(
        _ legacyKey: Curve25519.KeyAgreement.PrivateKey,
        service keychainService: String
    ) throws {
        let status = KeychainItem.store(legacyKey.rawRepresentation,
                                        account: Self.escrowKeychainAccount(forPublicKey: legacyKey.publicKey.rawRepresentation),
                                        service: keychainService,
                                        accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                        synchronizable: true)
        guard status != errSecSuccess else { return }
        FernletAuditLog.log("identity.escrow.legacyPromoteFailed", context: ["status": "\(status)"])
        throw IdentityError.keychainWriteFailed
    }

    // MARK: - Backup escrow key lifecycle (WS-1/WS-2/WS-3)

    /// The PUBLIC half of the backup-escrow key. Unlike the proximity key-agreement public key, the
    /// escrow key is synchronized via iCloud Keychain, so this value is STABLE across a user's devices.
    /// That is what lets a sealed-backup record sealed on one device be recognized as "mine" and
    /// restored on another (the proximity KA key is regenerated per device and must NOT bind backups).
    var localBackupEscrowPublicKey: Data {
        adopted?.publicKey.rawRepresentation ?? Data()
    }

    /// Sealed-backup key derivation, **record-format v1** (the legacy static derivation).
    ///
    /// ACCEPTED TRADE-OFF (explicit): a v1 backup is AES-GCM'd under a STATIC key —
    /// HKDF-SHA256(backupEscrowPrivateKey) with empty salt and fixed info, no ECDH and no ephemeral
    /// material — so there is NO forward secrecy, and a single escrow-key compromise decrypts every v1
    /// generation. That was intentional for a single-user, private-DB, recoverable-by-design backup: the
    /// escrow key itself is protected by iCloud Keychain end-to-end encryption, and a stable
    /// (non-ephemeral) key is what makes cross-device restore possible.
    ///
    /// **Record format v2 bounds that blast radius** (hardening #4): every backup generation mints its
    /// own 32-byte random HKDF salt, so a compromised escrow key derives one key per generation instead
    /// of one key for all of them. All new writes are v2 (``sealedBackupKey(formatVersion:salt:)``);
    /// this no-argument entry point remains v1 **and must not change** — it is the derivation that opens
    /// every v1 record already sitting in users' CloudKit databases, and its output is pinned by a
    /// known-answer vector in `SealedBackupFormatPinTests`.
    func sealedBackupKey() throws -> SymmetricKey {
        try sealedBackupKey(formatVersion: 1, salt: Data())
    }

    /// Sealed-backup key derivation for a specific record format.
    ///
    /// - Parameters:
    ///   - formatVersion: The record's format version. `1` (or anything below 2) reproduces the legacy
    ///     static derivation byte-for-byte — empty salt, info `com.fernlet.sealed-backup` — so records
    ///     in the wild keep opening. `2` (and above) mixes `salt` into HKDF under the versioned info
    ///     string `com.fernlet.sealed-backup.v2`.
    ///   - salt: The record's per-generation salt. Ignored for v1; for v2 it is the 32 random bytes
    ///     minted beside the generation counter and stamped on every chunk of that generation.
    /// - Returns: The 32-byte AES-GCM key for records of that format.
    /// - Throws: `IdentityError.notProvisioned` when no backup-escrow key has been adopted.
    func sealedBackupKey(formatVersion: Int, salt: Data) throws -> SymmetricKey {
        guard let adopted else { throw IdentityError.notProvisioned }
        return Self.deriveSealedBackupKey(from: adopted, formatVersion: formatVersion, salt: salt)
    }

    /// The HKDF derivation shared by `sealedBackupKey` and `sealedBackupKeyCandidates`. Pure (reads only
    /// its parameters + CryptoKit), so it is `nonisolated`.
    ///
    /// The version selects **both** the salt and the info string. The versioned info string is
    /// belt-and-suspenders on top of the salt: even a bug that produced an empty v2 salt could not
    /// collide with a v1 key, because the two derivations are domain-separated regardless.
    private nonisolated static func deriveSealedBackupKey(
        from privateKey: Curve25519.KeyAgreement.PrivateKey,
        formatVersion: Int,
        salt: Data
    ) -> SymmetricKey {
        let isV2 = formatVersion >= 2
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: privateKey.rawRepresentation),
            salt: isV2 ? salt : Data(),
            info: (isV2
                ? FernletCryptoPurpose.KeyDerivation.sealedBackupV2
                : FernletCryptoPurpose.KeyDerivation.sealedBackupLegacyV1).data,
            outputByteCount: 32
        )
    }

    // MARK: Content-addressed escrow slots

    /// Prefix for content-addressed escrow keychain accounts. The full account is `prefix + sha256hex(pub)`.
    /// `nonisolated` so the pure `escrowKeychainAccount(forPublicKey:)` can reference it off the main actor.
    private nonisolated static let escrowSlotPrefix = "backupEscrowPrivateKey.k."

    /// The content-addressed keychain account for an escrow key, derived from its PUBLIC key. Because the
    /// account is a function of the key's own content, two different escrow keys necessarily occupy two
    /// different accounts → two distinct iCloud-Keychain slots that coexist instead of overwriting. Exposed
    /// (nonisolated, pure) so the seal/restore tests and any tooling can address a key's slot deterministically.
    nonisolated static func escrowKeychainAccount(forPublicKey publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return escrowSlotPrefix + hex
    }

    /// One escrow key discovered in the keychain, coalesced across its synced/local rows. `synced` is true
    /// if ANY row for this key is synchronizable; `hasLocalRow` if a device-only row exists; `contentAddressed`
    /// if it lives at a content-addressed account (vs. only the legacy fixed account).
    private struct EscrowCandidate {
        let data: Data
        let key: Curve25519.KeyAgreement.PrivateKey
        let publicKey: Data
        var synced: Bool
        var hasLocalRow: Bool
        var contentAddressed: Bool
    }

    /// Enumerates every backup-escrow key present in this service's keychain — across content-addressed
    /// slots (synced + local) AND the legacy fixed account — coalescing each key's rows. Deterministically
    /// ordered (synced first, then by public-key hash ascending) so every device picks the SAME canonical
    /// key for sealing without coordination. A content-addressed row whose account does not equal
    /// `hash(its own public key)` is rejected as corrupt/foreign (cheap integrity check).
    private func gatherEscrowCandidates(service keychainService: String) -> [EscrowCandidate] {
        var byData: [Data: EscrowCandidate] = [:]
        func ingest(account: String, data: Data, synced: Bool) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return }
            let pub = key.publicKey.rawRepresentation
            let isContentAddressed = account.hasPrefix(Self.escrowSlotPrefix)
            if isContentAddressed && account != Self.escrowKeychainAccount(forPublicKey: pub) { return }
            if var existing = byData[data] {
                existing.synced = existing.synced || synced
                existing.hasLocalRow = existing.hasLocalRow || !synced
                existing.contentAddressed = existing.contentAddressed || isContentAddressed
                byData[data] = existing
            } else {
                byData[data] = EscrowCandidate(data: data, key: key, publicKey: pub,
                                               synced: synced, hasLocalRow: !synced,
                                               contentAddressed: isContentAddressed)
            }
        }
        for (account, data) in KeychainItem.loadAll(service: keychainService, synchronizable: .synced)
        where account.hasPrefix(Self.escrowSlotPrefix) {
            ingest(account: account, data: data, synced: true)
        }
        for (account, data) in KeychainItem.loadAll(service: keychainService, synchronizable: .local)
        where account.hasPrefix(Self.escrowSlotPrefix) {
            ingest(account: account, data: data, synced: false)
        }
        // Legacy fixed account — READ ONLY for back-compat with pre-content-addressing devices.
        let legacy = IdentityKeychainKey.backupEscrowPrivateKey.rawValue
        if let data = KeychainItem.load(account: legacy, service: keychainService, synchronizable: .synced) {
            ingest(account: legacy, data: data, synced: true)
        }
        if let data = KeychainItem.load(account: legacy, service: keychainService, synchronizable: .local) {
            ingest(account: legacy, data: data, synced: false)
        }
        return byData.values.sorted { lhs, rhs in
            if lhs.synced != rhs.synced { return lhs.synced && !rhs.synced }
            return Self.escrowKeychainAccount(forPublicKey: lhs.publicKey)
                 < Self.escrowKeychainAccount(forPublicKey: rhs.publicKey)
        }
    }

    /// Loads the CANONICAL backup-escrow private key present in the keychain (synced preferred, then the
    /// smallest public-key hash — a deterministic, cross-device-stable choice), or nil if none exists.
    /// NEVER mints — the open/restore path relies on this so a missing key surfaces as "not synced yet",
    /// never a divergent new identity. When >1 key coexists (a conflict) the canonical one is returned for
    /// sealing/boot consistency; `reconcileBackupEscrowKey` separately surfaces the conflict non-silently.
    private func loadExistingEscrowKey(service keychainService: String) -> Curve25519.KeyAgreement.PrivateKey? {
        gatherEscrowCandidates(service: keychainService).first?.key
    }

    /// SEAL/enable path. Ensures `adopted` is set so a sealed backup can be produced, without
    /// stranding cross-device restore: re-queries the keychain for a synced (or already-minted local)
    /// escrow key first and adopts it; only when none exists does it mint one — and that fresh key is
    /// stored `ThisDeviceOnly` (WS-2), never published as `synchronizable` until a later launch confirms
    /// no conflicting synced key has appeared (`reconcileBackupEscrowKey`). The minted key is stored at its
    /// CONTENT-ADDRESSED account, so even if it is later promoted it can never overwrite a different
    /// (genuine) key — the publish targets this key's own slot. Returns the escrow public key.
    ///
    /// Reads no namespace verdict: Fernlet's sealed backup, whose callers run the identity's
    /// `ensureProvisioned()` first.
    @discardableResult
    func provisionBackupEscrowKeyForSealing(service keychainService: String) -> Data {
        if adopted == nil { adopted = loadExistingEscrowKey(service: keychainService) }
        if adopted == nil {
            let minted = Curve25519.KeyAgreement.PrivateKey()
            let account = Self.escrowKeychainAccount(forPublicKey: minted.publicKey.rawRepresentation)
            let status = KeychainItem.store(minted.rawRepresentation,
                                            account: account,
                                            service: keychainService,
                                            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                            synchronizable: false)
            // Adopt the minted key ONLY once it is provably on disk. Adopting an unwritten key
            // seals every backup generation under a key that exists nowhere after relaunch —
            // permanently unrecoverable records. Empty return = "no escrow key", which the seal
            // path already treats as refuse-to-seal (`sealedBackupKey` throws `notProvisioned`).
            guard status == errSecSuccess else {
                FernletAuditLog.log("identity.escrow.mintFailed", context: ["status": "\(status)"])
                return Data()
            }
            guard KeychainItem.load(account: account, service: keychainService, synchronizable: .local)
                    == minted.rawRepresentation else {
                FernletAuditLog.log("identity.escrow.mintVerifyFailed")
                return Data()
            }
            adopted = minted
            FernletAuditLog.log("identity.escrow.mintedLocal")
        }
        return adopted?.publicKey.rawRepresentation ?? Data()
    }

    /// OPEN/restore path. Loads an existing escrow key (canonical, synced preferred) into memory; NEVER
    /// mints. Returns whether a key is present — `false` means "not synced yet", which the restore flow
    /// surfaces as a retryable state (WS-4) rather than fabricating a new identity.
    func loadBackupEscrowKeyForOpen(service keychainService: String) -> Bool {
        if adopted == nil { adopted = loadExistingEscrowKey(service: keychainService) }
        return adopted != nil
    }

    /// Every backup-escrow key available to this device — the adopted (canonical) key plus any other
    /// coexisting content-addressed / legacy keys — as (escrow public key, derived AES-GCM key) pairs,
    /// adopted key first. The open/restore path tries each (decrypt-first) so a record sealed under a
    /// SURVIVING-but-not-adopted key — e.g. during an as-yet-unresolved cross-device escrow conflict —
    /// still restores with no manual step. Content-addressing is what guarantees those keys coexist (rather
    /// than one having silently overwritten the other), which is the whole point of trying them.
    ///
    /// Derives under **record format v1** (static, empty salt). Use
    /// ``sealedBackupKeyCandidates(formatVersion:salt:service:)`` to open a v2 record.
    func sealedBackupKeyCandidates(service keychainService: String) -> [(publicKey: Data, key: SymmetricKey)] {
        sealedBackupKeyCandidates(formatVersion: 1, salt: Data(), service: keychainService)
    }

    /// The same candidate set as ``sealedBackupKeyCandidates(service:)``, derived under a specific record
    /// format.
    ///
    /// The format changes only the *derived key* of each pair, never **which** escrow identities exist:
    /// the returned `publicKey` values (and therefore the count and order) are identical for every
    /// version, so the identity-tag classification in the open path is version-independent.
    ///
    /// - Parameters:
    ///   - formatVersion: The version of the record being opened (`1` legacy static, `2` salted).
    ///   - salt: That record's per-generation salt; ignored for v1.
    ///   - keychainService: The identity's keychain service, where the escrow rows live.
    /// - Returns: (escrow public key, derived AES-GCM key) pairs, adopted key first.
    func sealedBackupKeyCandidates(
        formatVersion: Int, salt: Data, service keychainService: String
    ) -> [(publicKey: Data, key: SymmetricKey)] {
        var pairs: [(publicKey: Data, key: SymmetricKey)] = []
        var seen = Set<Data>()
        func add(_ privateKey: Curve25519.KeyAgreement.PrivateKey) {
            let pub = privateKey.publicKey.rawRepresentation
            guard seen.insert(pub).inserted else { return }
            pairs.append((
                publicKey: pub,
                key: Self.deriveSealedBackupKey(from: privateKey, formatVersion: formatVersion, salt: salt)
            ))
        }
        if let adopted { add(adopted) }
        for candidate in gatherEscrowCandidates(service: keychainService) { add(candidate.key) }
        return pairs
    }

    /// Launch-time reconciliation of the backup-escrow key across iCloud Keychain (WS-3). Resolves, NON-
    /// SILENTLY, the states that deferred/ThisDeviceOnly minting can leave behind:
    /// - a synced key present → adopt it (authoritative); tidy a redundant identical local copy.
    /// - only a local minted key present → publish (promote) it to `synchronizable` so a future device
    ///   can restore. This runs at launch, necessarily a DIFFERENT launch than the one that minted the
    ///   key (the user enables a backup mid-session, after this has already run), honoring WS-2's
    ///   "promote only on a later launch once no conflicting synced key has appeared".
    /// - a synced key that DIFFERS from the local minted key → a genuine cross-device conflict. Do NOT
    ///   overwrite either side; return `.conflict` so the caller can surface a user choice and let the
    ///   user adopt the authoritative key + re-upload. Every branch is audited.
    ///
    /// MECHANISM + WHY THE RESIDUAL IS NOW GONE. Apple's iCloud Keychain (confirmed from the open-source
    /// `SecItemDataSource.c` conflict resolver + patents US9077759B2 / US9479583B2) treats
    /// `kSecAttrSynchronizable` + service + account as an item's primary key and resolves a divergence on a
    /// SHARED slot by **newest `kSecAttrModificationDate` wins** — no value coexistence, no merge callback.
    /// The old fixed-account design therefore had a residual: a divergent (newer) key could silently
    /// overwrite the genuine (older) key cross-device, permanently stranding the origin's backups. This
    /// build removes that by CONTENT-ADDRESSING the slot (`escrowKeychainAccount(forPublicKey:)`): two
    /// different keys have different accounts → different slots → they COEXIST. A promote/publish therefore
    /// always targets the publishing key's OWN slot and can only ever overwrite an identical copy of the
    /// same key, never a different genuine one. Divergence is now an additive, DETECTABLE state (≥2
    /// coexisting keys) surfaced as a NON-SILENT `.conflict`, not a destructive overwrite — and because all
    /// keys survive, the origin's backups are always recoverable and restore can try every key (decrypt-
    /// first, `sealedBackupKeyCandidates`). WS-2's withhold-then-promote is kept (mint ThisDeviceOnly, publish
    /// on a later launch only when no other key is present) to minimize needless key proliferation.
    func reconcileBackupEscrowKey(service keychainService: String) -> IdentityService.BackupEscrowReconcileOutcome {
        let candidates = gatherEscrowCandidates(service: keychainService)
        switch candidates.count {
        case 0:
            return .noEscrow
        case 1:
            let only = candidates[0]
            adopted = only.key
            if only.synced {
                // Already published. Tidy a now-redundant device-only copy at this key's content-addressed
                // account (the publish below would otherwise leave it lingering). Removing only the .local
                // row for THIS key's account cannot disturb any other (different) key.
                if only.hasLocalRow && only.contentAddressed {
                    KeychainItem.delete(account: Self.escrowKeychainAccount(forPublicKey: only.publicKey),
                                        service: keychainService, synchronizable: .local)
                }
                // Migrate a genuine key that still lives ONLY at the legacy fixed account onto its
                // content-addressed slot, so legacy-origin keys gain the same overwrite-immunity as newly
                // minted ones (closes the last fixed-slot exposure for upgraded users). ADDITIVE: we write
                // the CA synced row and NEVER delete the legacy row — a still-old-build device keeps reading
                // it, and `gatherEscrowCandidates` coalesces the identical bytes into ONE candidate, so this
                // raises no false conflict and preserves zero-config recovery. Idempotent: once a CA row
                // exists, `only.contentAddressed` is true and this no-ops.
                if !only.contentAddressed {
                    let status = KeychainItem.store(only.data,
                                                    account: Self.escrowKeychainAccount(forPublicKey: only.publicKey),
                                                    service: keychainService,
                                                    accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                                    synchronizable: true, replacing: .local)
                    // Log what actually happened: the pre-fix code logged the migration as done
                    // even when nothing was written.
                    if status == errSecSuccess {
                        FernletAuditLog.log("identity.escrow.migratedLegacyToContentAddressed")
                    } else {
                        FernletAuditLog.log("identity.escrow.migrateFailed", context: ["status": "\(status)"])
                    }
                }
                return .usingSynced
            }
            // Only a device-only key exists → promote (publish) it to synchronizable at its CONTENT-
            // ADDRESSED account. ADD-THEN-DELETE: the synced row is written first (`replacing: .synced`
            // can only ever displace an identical copy of THIS key, since the account is a hash of its
            // own public key), and the device-only row — potentially the last copy of the key — is
            // removed only after the publish is confirmed. The old delete-then-add order meant a failed
            // publish destroyed that last copy.
            let account = Self.escrowKeychainAccount(forPublicKey: only.publicKey)
            let status = KeychainItem.store(only.data, account: account, service: keychainService,
                                            accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                            synchronizable: true, replacing: .synced)
            guard status == errSecSuccess else {
                FernletAuditLog.log("identity.escrow.promoteFailed", context: ["status": "\(status)"])
                return .promotedLocal
            }
            KeychainItem.delete(account: account, service: keychainService, synchronizable: .local)
            FernletAuditLog.log("identity.escrow.promotedLocal")
            return .promotedLocal
        default:
            // ≥2 distinct keys coexist — content-addressing kept them all alive (none overwrote another).
            // Adopt the canonical one so sealing/boot is consistent, but surface a non-silent `.conflict`;
            // the user resolves via `adoptSyncedBackupEscrowKey`. Restore meanwhile still works against any
            // of the surviving keys, so no data is stranded while the conflict is unresolved.
            adopted = candidates[0].key
            FernletAuditLog.log("identity.escrow.conflictDetected")
            return .conflict
        }
    }

    /// WS-3 user-confirmed resolution of an escrow `.conflict`: adopt the canonical SYNCED (other-device)
    /// key as authoritative and discard THIS device's divergent device-only key(s). The caller MUST warn
    /// the user first and re-upload any device-local backups under the adopted key. Returns the adopted
    /// escrow public key, or nil if no synced key is present. (Only this device's local-only content-
    /// addressed rows are removed; synced keys are never deleted, so nothing is destroyed cross-device — a
    /// deeper conflict between two SYNCED keys keeps surfacing until the devices converge.)
    func adoptSyncedBackupEscrowKey(service keychainService: String) -> Data? {
        let candidates = gatherEscrowCandidates(service: keychainService)
        guard let chosen = candidates.first(where: { $0.synced }) else { return nil }
        for candidate in candidates where !candidate.synced && candidate.contentAddressed && candidate.data != chosen.data {
            KeychainItem.delete(account: Self.escrowKeychainAccount(forPublicKey: candidate.publicKey),
                                service: keychainService, synchronizable: .local)
        }
        adopted = chosen.key
        FernletAuditLog.log("identity.escrow.adoptedSynced")
        return chosen.publicKey
    }
}

// MARK: - Fernlet's identity and its escrow

extension IdentityService {

    /// Fernlet's device identity: `ProximityNamespace.fernlet`'s, on `keychainService` (`nil`, every
    /// shipping path, for `.fernlet`'s identity service, `com.fernlet.identity`), carrying a fresh
    /// ``SealedBackupEscrowKey`` as its provisioning participant.
    ///
    /// The one factory every identity the app builds goes through (`FernletStore`'s
    /// `makeProximityIdentity()` answers it for the proximity managers), so each of them runs the
    /// escrow's provisioning cases, whichever provisions first on a device: Case 3 promotes a previous
    /// build's synced key-agreement key into its escrow slot before any mint overwrites the row.
    /// `KeyCustodyBoundaryTests.everyShippingIdentityIsBuiltByItsHostsDoor` holds every shipping
    /// construction to this file and ProximityKit's host default.
    ///
    /// - Parameter keychainService: The service holding the identity's rows, or `nil` for Fernlet's.
    /// - Returns: An identity that reads and writes nothing until it is provisioned.
    static func fernletApp(keychainService: String? = nil) -> IdentityService {
        IdentityService(namespace: .fernlet, keychainService: keychainService,
                        provisioningParticipant: SealedBackupEscrowKey())
    }

    /// Outcome of `reconcileBackupEscrowKey`. Each case is a NON-SILENT, audited resolution of the states
    /// that deferred (WS-1) / ThisDeviceOnly (WS-2) escrow minting can leave across a user's devices.
    enum BackupEscrowReconcileOutcome: Equatable {
        /// No escrow material anywhere — sealed backup was never enabled on any synced device yet.
        case noEscrow
        /// A synced (authoritative) key is present and adopted.
        case usingSynced
        /// A device-only minted key was published (promoted) to `synchronizable` for cross-device restore.
        case promotedLocal
        /// ≥2 distinct escrow keys COEXIST (content-addressing kept them all alive rather than overwriting)
        /// — a real cross-device conflict. Not auto-resolved; the caller must surface a user choice (WS-3).
        /// Restore still works against any surviving key meanwhile, so nothing is stranded.
        case conflict
    }

    /// This identity's sealed-backup escrow key: its provisioning participant when that is Fernlet's,
    /// as on every identity `fernletApp(keychainService:)` builds, and nil otherwise.
    private var sealedBackupEscrow: SealedBackupEscrowKey? {
        provisioningParticipant as? SealedBackupEscrowKey
    }

    /// The PUBLIC half of the adopted backup-escrow key (``SealedBackupEscrowKey/localBackupEscrowPublicKey``),
    /// stable across a user's devices; empty when none is adopted or the identity carries no escrow.
    var localBackupEscrowPublicKey: Data {
        sealedBackupEscrow?.localBackupEscrowPublicKey ?? Data()
    }

    /// The record-format v1 sealed-backup key (``SealedBackupEscrowKey/sealedBackupKey()``).
    ///
    /// - Throws: `IdentityError.notProvisioned` when no backup-escrow key has been adopted, or the
    ///   identity carries no escrow.
    func sealedBackupKey() throws -> SymmetricKey {
        guard let escrow = sealedBackupEscrow else { throw IdentityError.notProvisioned }
        return try escrow.sealedBackupKey()
    }

    /// The sealed-backup key for a record format (``SealedBackupEscrowKey/sealedBackupKey(formatVersion:salt:)``).
    ///
    /// - Parameters:
    ///   - formatVersion: The record's format version (`1` legacy static, `2` salted).
    ///   - salt: The record's per-generation salt; ignored for v1.
    /// - Returns: The 32-byte AES-GCM key for records of that format.
    /// - Throws: `IdentityError.notProvisioned` when no backup-escrow key has been adopted, or the
    ///   identity carries no escrow.
    func sealedBackupKey(formatVersion: Int, salt: Data) throws -> SymmetricKey {
        guard let escrow = sealedBackupEscrow else { throw IdentityError.notProvisioned }
        return try escrow.sealedBackupKey(formatVersion: formatVersion, salt: salt)
    }

    /// The seal/enable path (``SealedBackupEscrowKey/provisionBackupEscrowKeyForSealing(service:)``) on
    /// this identity's keychain service: adopts the escrow key present, or mints one device-only.
    ///
    /// - Returns: The escrow public key, or empty when none could be adopted or minted, or the
    ///   identity carries no escrow.
    @discardableResult
    func provisionBackupEscrowKeyForSealing() -> Data {
        sealedBackupEscrow?.provisionBackupEscrowKeyForSealing(service: keychainService) ?? Data()
    }

    /// The open/restore path (``SealedBackupEscrowKey/loadBackupEscrowKeyForOpen(service:)``) on this
    /// identity's keychain service; never mints.
    ///
    /// - Returns: Whether an escrow key is present; `false` too when the identity carries no escrow.
    func loadBackupEscrowKeyForOpen() -> Bool {
        sealedBackupEscrow?.loadBackupEscrowKeyForOpen(service: keychainService) ?? false
    }

    /// Every escrow key available to this device under record format v1
    /// (``SealedBackupEscrowKey/sealedBackupKeyCandidates(service:)``), adopted key first; empty when the
    /// identity carries no escrow.
    func sealedBackupKeyCandidates() -> [(publicKey: Data, key: SymmetricKey)] {
        sealedBackupEscrow?.sealedBackupKeyCandidates(service: keychainService) ?? []
    }

    /// The same candidates under a specific record format
    /// (``SealedBackupEscrowKey/sealedBackupKeyCandidates(formatVersion:salt:service:)``); empty when the
    /// identity carries no escrow.
    ///
    /// - Parameters:
    ///   - formatVersion: The version of the record being opened (`1` legacy static, `2` salted).
    ///   - salt: That record's per-generation salt; ignored for v1.
    /// - Returns: (escrow public key, derived AES-GCM key) pairs, adopted key first.
    func sealedBackupKeyCandidates(formatVersion: Int, salt: Data) -> [(publicKey: Data, key: SymmetricKey)] {
        sealedBackupEscrow?.sealedBackupKeyCandidates(
            formatVersion: formatVersion, salt: salt, service: keychainService) ?? []
    }

    /// Launch-time reconciliation of the escrow key (``SealedBackupEscrowKey/reconcileBackupEscrowKey(service:)``)
    /// on this identity's keychain service; `.noEscrow` when the identity carries no escrow.
    func reconcileBackupEscrowKey() -> BackupEscrowReconcileOutcome {
        sealedBackupEscrow?.reconcileBackupEscrowKey(service: keychainService) ?? .noEscrow
    }

    /// The user-confirmed resolution of an escrow conflict
    /// (``SealedBackupEscrowKey/adoptSyncedBackupEscrowKey(service:)``) on this identity's keychain service.
    ///
    /// - Returns: The adopted escrow public key, or nil when no synced key is present or the identity
    ///   carries no escrow.
    func adoptSyncedBackupEscrowKey() -> Data? {
        sealedBackupEscrow?.adoptSyncedBackupEscrowKey(service: keychainService)
    }

    /// The content-addressed keychain account for an escrow key
    /// (``SealedBackupEscrowKey/escrowKeychainAccount(forPublicKey:)``): `backupEscrowPrivateKey.k.` +
    /// the lowercase hex SHA-256 of `publicKey`. `nonisolated`, pure, like the static it forwards to.
    ///
    /// - Parameter publicKey: The escrow key's raw X25519 public key.
    /// - Returns: The account its rows live at.
    nonisolated static func escrowKeychainAccount(forPublicKey publicKey: Data) -> String {
        SealedBackupEscrowKey.escrowKeychainAccount(forPublicKey: publicKey)
    }
}
