// KeychainHelpers.swift
// Fernlet
//
// Generic Keychain accessors shared by FernletLockService and IdentityService.
// Lock-specific typed wrappers (LockKeychainKey) live in FernletLockService.swift.

import CryptoKit
import Foundation
import Security

/// Generic data-protection Keychain accessors shared by Fernlet's key and preference stores.
///
/// The common substrate for every keychain-backed secret in the app: `FernletLockService`'s lock
/// credentials, `IdentityService`'s mesh identity and backup-escrow keys, the device-bound
/// journal and Worry Box content keys, and the persisted ``StoragePreferences`` blob. All
/// operations target generic-password items in the data-protection keychain
/// (`kSecUseDataProtectionKeychain`), keyed by service + account.
///
/// Two subtleties are load-bearing:
/// - The keychain treats `kSecAttrSynchronizable` as part of an item's primary key, so an
///   iCloud-synced item and a `ThisDeviceOnly` item can coexist under the same service + account
///   as two distinct rows. ``SynchronizableScope`` lets callers target one variant; the
///   backup-escrow reconciliation depends on telling them apart.
/// - ``store(_:account:service:accessibility:synchronizable:replacing:)`` is delete-then-add, and
///   its `replacing` scope controls which variant the delete removes — pass a narrow scope when
///   promoting an escrow item so a genuine key that just synced in is not clobbered.
///
/// Lock-specific typed wrappers (`LockKeychainKey`) live in `FernletLockService`; this type stays
/// mechanism-only. `nonisolated`: pure Security-framework calls with no shared state, callable
/// from any executor.
public nonisolated enum KeychainItem {
    /// Well-known account names for Fernlet's own keychain items.
    ///
    /// Each case is the literal `kSecAttrAccount` string under which one of the app's
    /// device-bound secrets is stored. The typed convenience overloads
    /// (``store(_:for:service:)``, ``load(for:service:)``, ``delete(for:service:)``) take an
    /// `Account` and pin `AfterFirstUnlockThisDeviceOnly` accessibility.
    public enum Account: String {
        /// The JSON-encoded ``StoragePreferences`` blob persisted by ``StoragePreferencesStore``.
        case storagePreferences = "com.fernlet.storage-preferences.preferences"
        /// Device-bound fallback key sealing journal narratives when no user lock is configured
        /// or the lock is closed.
        case deviceJournalKey = "com.fernlet.journal.deviceKey"
        /// Device-bound fallback key for Worry Box notes (sealed, local-only) when no user lock is
        /// configured or the lock is closed. Lives under `journalService` beside the journal device key
        /// so lock reset (`KeychainItem.deleteAll`-adjacent flows) treats the sealed-content keys alike.
        case deviceWorryKey = "com.fernlet.worry.deviceKey"
    }

    /// Which synchronizable variant of an item a query should match.
    ///
    /// The default `.any` preserves the
    /// historical behavior (`kSecAttrSynchronizableAny`). `.synced` / `.local` let a caller distinguish
    /// an iCloud-Keychain-replicated item from a `ThisDeviceOnly` one when BOTH can exist under the same
    /// service+account — the keychain treats `kSecAttrSynchronizable` as part of an item's primary key,
    /// so a synced item and a device-only item with the same account coexist as two distinct rows. The
    /// backup-escrow reconciliation relies on telling them apart (see IdentityService).
    public enum SynchronizableScope {
        /// Match either variant (`kSecAttrSynchronizableAny`) — the historical default behavior.
        case any
        /// Match only the iCloud-Keychain-replicated variant.
        case synced
        /// Match only the `ThisDeviceOnly` (non-synchronizable) variant.
        case local

        fileprivate var queryValue: Any {
            switch self {
            case .any:    return kSecAttrSynchronizableAny
            case .synced: return true
            case .local:  return false
            }
        }
    }

    /// Three-way result of a keychain read that distinguishes "no such item" from "the keychain
    /// could not be read" — the distinction ``load(account:service:synchronizable:)`` deliberately
    /// collapses into `nil`. Stores that mint a fresh secret on absence use it to fail closed on a
    /// transient error instead of minting over an unreadable row.
    public enum ReadResult {
        /// The item exists; carries its data.
        case found(Data)
        /// No item matches the query (`errSecItemNotFound`) — safe to treat as "never stored".
        case absent
        /// The keychain call failed (any other `OSStatus`), or reported success without returning
        /// data; the item's existence is unknown, so callers must not mint a replacement.
        case unreadable(OSStatus)
    }

    /// Two-way result of a keychain ENUMERATION that distinguishes "this service holds nothing"
    /// from "this service could not be read" — the distinction ``loadAll(service:synchronizable:)``
    /// deliberately collapses into `[]`. Callers whose contract is a promise ABOUT the row set (the
    /// delete-everything funnel, which reports a store as incompletely cleared) use it so an
    /// unreadable keychain cannot read as an empty one.
    public enum EnumerationResult {
        /// The enumeration succeeded; carries every matching item. An EMPTY array is a genuine
        /// empty slot (`errSecItemNotFound`, or a success with no decodable rows), not a failure.
        case rows([(account: String, data: Data)])
        /// The keychain call failed (any status other than success and `errSecItemNotFound`), or
        /// reported success without returning the attribute array the query asked for. The row set
        /// is UNKNOWN — never treat it as empty. In the second case the carried status is
        /// `errSecSuccess`: the *case*, not the status, is the failure signal.
        case unreadable(OSStatus)
    }

    /// Service string for the app-lock credentials (`FernletLockService`'s production slot).
    nonisolated public static let productionService = "com.fernlet.lock"
    /// Service string under which the ``StoragePreferences`` blob is stored.
    nonisolated public static let storagePreferencesService = "com.fernlet.storage-preferences"
    /// Service string for the sealed-content device keys (journal and Worry Box).
    nonisolated public static let journalService = "com.fernlet.journal"

    // MARK: - Generic String-keyed operations

    /// Stores `data`, first removing any colliding item. `replacing` controls WHICH synchronizable
    /// variant is removed before the add: the default `.any` matches the historical "overwrite whatever
    /// is there" behavior. Pass `.local` (or `.synced`) to remove only that variant — used when
    /// promoting a `ThisDeviceOnly` escrow item to `synchronizable` without risking the removal of a
    /// genuine key that just synced in under the same account.
    ///
    /// - Returns: the `SecItemAdd` status (`errSecSuccess` on success). Not discardable (R7): a
    ///   failed add means the secret was never persisted, and every caller here is minting key
    ///   material whose loss is silent until the next read.
    public static func store(
        _ data: Data,
        account: String,
        service: String,
        accessibility: CFString,
        synchronizable: Bool = false,
        replacing: SynchronizableScope = .any
    ) -> OSStatus {
        // R5: an empty account/service/payload is a caller bug, not a keychain condition — SecItemAdd
        // would happily file a row under an empty key that no typed load ever finds again.
        guard !account.isEmpty, !service.isEmpty, !data.isEmpty else { return errSecParam }
        delete(account: account, service: service, synchronizable: replacing)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessibility,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Loads the data of the single item matching `service` + `account` within `synchronizable`
    /// scope, or `nil` when no item matches (or the keychain call fails).
    public static func load(account: String, service: String, synchronizable: SynchronizableScope = .any) -> Data? {
        guard !account.isEmpty, !service.isEmpty else { return nil }   // R5: no row is ever filed under an empty key.
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Loads the single item matching `service` + `account` within `synchronizable` scope,
    /// distinguishing the three outcomes ``load(account:service:synchronizable:)`` collapses:
    /// ``ReadResult/found(_:)`` with the item's data, ``ReadResult/absent`` when no item exists,
    /// and ``ReadResult/unreadable(_:)`` carrying the failing `OSStatus`. Used by stores whose
    /// mint-fresh-on-absent path must fail closed on a transient read error (the heart-drop
    /// prekey blob and the sidecar seal key) and by
    /// `StoragePreferencesStore.persistedBlobState`, the backup-exclusion launch gate's read —
    /// which must not treat a pre-first-unlock `errSecInteractionNotAllowed` as "never stored".
    public static func loadDistinguishingAbsence(
        account: String,
        service: String,
        synchronizable: SynchronizableScope = .any
    ) -> ReadResult {
        // R5: an empty key can never have been stored, but it is a caller bug rather than a clean
        // absence — report it as unreadable so mint-on-absent callers fail closed instead of minting.
        guard !account.isEmpty, !service.isEmpty else { return .unreadable(errSecParam) }
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .unreadable(status) }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        default:
            return .unreadable(status)
        }
    }

    /// Enumerates EVERY generic-password item under `service` (optionally restricted to a synchronizable
    /// scope), returning each item's account + data. Used by the content-addressed backup-escrow store:
    /// because each escrow key lives at an account derived from its own public key, divergent keys land on
    /// DIFFERENT accounts and coexist rather than overwrite one another — so the reconcile path must
    /// enumerate to discover the full set (a fresh device does not know the account name a priori). Query
    /// `.synced` and `.local` separately to learn each row's sync status. Returns `[]` on no match/error.
    ///
    /// - Important: the error collapse is the whole difference from
    ///   ``loadAllDistinguishingFailure(service:synchronizable:)``, and it is only safe where an
    ///   unreadable service and an empty one warrant the same behavior — the escrow reconcile
    ///   discovers nothing to reconcile and simply retries later. A caller that PROMISES something
    ///   about the row set (that it cleared them all, that none remain) must use the distinguishing
    ///   variant instead: `[]` from an unreadable keychain would make that promise a lie.
    public static func loadAll(service: String, synchronizable: SynchronizableScope = .any) -> [(account: String, data: Data)] {
        switch loadAllDistinguishingFailure(service: service, synchronizable: synchronizable) {
        case .rows(let rows):  return rows
        case .unreadable:      return []   // the documented collapse; see the note above.
        }
    }

    /// ``loadAll(service:synchronizable:)`` reporting its outcome: the rows, or the `OSStatus` that
    /// stopped the enumeration from producing them.
    ///
    /// The distinction is load-bearing exactly where a promise is being made about the row set.
    /// `ModerationBanStore.clearPeerBansForDeleteAll` is the caller it was added for: it enumerates
    /// the moderation service to find every peer-ban row to delete, and under the collapsing
    /// variant a failed enumeration produced an empty account list — zero deletes, zero failures,
    /// and a CLEAN result reported to the "Delete everything" dialog over peer-ban records still
    /// sitting in the keychain. `errSecItemNotFound` is NOT such a failure: a service that holds
    /// nothing is a legitimately empty one, and it lands in ``EnumerationResult/rows(_:)`` as `[]`.
    public static func loadAllDistinguishingFailure(
        service: String,
        synchronizable: SynchronizableScope = .any
    ) -> EnumerationResult {
        // R5: an empty service is a caller bug rather than an empty slot — report it as unreadable
        // so a caller promising it cleared the slot fails closed instead of promising it cleared "".
        guard !service.isEmpty else { return .unreadable(errSecParam) }
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return enumerationResult(status: status, matches: result as? [[String: Any]])
    }

    /// Classifies one `SecItemCopyMatching` enumeration into an ``EnumerationResult`` — the pure
    /// status-to-outcome mapping inside ``loadAllDistinguishingFailure(service:synchronizable:)``.
    ///
    /// Split out (and reachable) because it is the half the wipe funnel's honesty rests on —
    /// `errSecItemNotFound` is an empty slot, every other failing status is an unknown one — while
    /// the statuses that matter most (`errSecInteractionNotAllowed` before first unlock,
    /// `errSecNotAvailable`) cannot be provoked against a simulator keychain. Pure: it performs no
    /// keychain call and holds no state.
    ///
    /// - Parameters:
    ///   - status: the status `SecItemCopyMatching` returned.
    ///   - matches: its out-parameter cast to the attribute dictionaries the query asked for, or
    ///     `nil` when it returned nothing (as `errSecItemNotFound` does) or a value of another shape.
    public static func enumerationResult(status: OSStatus, matches: [[String: Any]]?) -> EnumerationResult {
        switch status {
        case errSecSuccess:
            guard let matches else { return .unreadable(status) }
            // Bounded: one pass over the finite row set the keychain returned. A row missing either
            // attribute is dropped rather than failing the whole enumeration — it is not one of ours.
            let rows: [(account: String, data: Data)] = matches.compactMap { item in
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data else { return nil }
                return (account, data)
            }
            return .rows(rows)
        case errSecItemNotFound:
            return .rows([])
        default:
            return .unreadable(status)
        }
    }

    /// Deletes the item matching `service` + `account` within `synchronizable` scope. A no-match
    /// result is silently ignored, so the call is safe to make unconditionally.
    ///
    /// R7: `SecItemDelete`'s status is inspected rather than dropped. `errSecItemNotFound` is the
    /// documented benign outcome; anything else (`errSecInteractionNotAllowed` before first unlock,
    /// `errSecNotAvailable`) means a row the lock-reset / delete-everything flows believe they
    /// removed is still there, so it is audited. Use ``deleteReportingStatus(account:service:synchronizable:)``
    /// where the caller must act on that.
    public static func delete(account: String, service: String, synchronizable: SynchronizableScope = .any) {
        let status = deleteReportingStatus(account: account, service: service, synchronizable: synchronizable)
        guard status != errSecSuccess else { return }
        FernletAuditLog.log("keychain.delete.failed", context: [
            "service": service, "account": account, "status": "\(status)"
        ])
    }

    /// ``delete(account:service:synchronizable:)`` reporting its outcome: `errSecSuccess` when the
    /// row is gone (including the `errSecItemNotFound` "was never there" case, normalized), else the
    /// failing `OSStatus`. For callers whose contract depends on the row actually being removed.
    public static func deleteReportingStatus(
        account: String,
        service: String,
        synchronizable: SynchronizableScope = .any
    ) -> OSStatus {
        guard !account.isEmpty, !service.isEmpty else { return errSecParam }   // R5: nothing is filed under an empty key.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    /// Replaces the VALUE of the single existing item matching `service` + `account` within
    /// `synchronizable` scope via one `SecItemUpdate` — **update-only**: when no item matches,
    /// `errSecItemNotFound` is returned *un-normalized* and nothing is created. The caller must
    /// refuse to create; a caller that needs create-or-replace uses
    /// ``store(_:account:service:accessibility:synchronizable:replacing:)`` instead.
    ///
    /// Why this exists beside the delete-then-add `store`: `SecItemUpdate` is applied by securityd
    /// (out of process) as a single transaction, so the client dying mid-call cannot leave the row
    /// absent or half-written — the property the lock's wrap re-wrap promote (crypto-standardization
    /// Phase 2.5) depends on, where `store`'s two-transaction delete-then-add has a real
    /// row-absent crash window. Only `kSecValueData` appears in `attributesToUpdate`, so the row's
    /// accessibility class and synchronizable flag are preserved exactly as stored.
    ///
    /// - Returns: the raw `SecItemUpdate` status (`errSecSuccess` on success; `errSecItemNotFound`
    ///   when no row matched — deliberately NOT normalized, unlike the delete family). R5: empty
    ///   account/service/payload are caller bugs, refused with `errSecParam` (matching `store`).
    ///   R7: not discardable — a failed update means the value was never replaced.
    public static func updateReportingStatus(
        _ data: Data,
        account: String,
        service: String,
        synchronizable: SynchronizableScope = .any
    ) -> OSStatus {
        guard !account.isEmpty, !service.isEmpty, !data.isEmpty else { return errSecParam }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]
        return SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    }

    /// Deletes EVERY item under `service`, both synced and device-only variants. Used by the
    /// lock-reset and delete-everything flows to clear a whole service slot at once.
    ///
    /// R7: a non-benign `SecItemDelete` status is audited rather than dropped — these flows promise
    /// the slot is empty afterwards.
    public static func deleteAll(service: String) {
        let status = deleteAllReportingStatus(service: service)
        guard status != errSecSuccess else { return }
        FernletAuditLog.log("keychain.deleteAll.failed", context: ["service": service, "status": "\(status)"])
    }

    /// ``deleteAll(service:)`` reporting its outcome, with `errSecItemNotFound` normalized to
    /// `errSecSuccess` (an empty slot is a cleared slot).
    public static func deleteAllReportingStatus(service: String) -> OSStatus {
        guard !service.isEmpty else { return errSecParam }   // R5: refuse to sweep an unnamed slot.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    // MARK: - Account typed convenience (AfterFirstUnlockThisDeviceOnly)

    /// Stores `data` for a well-known ``Account``, pinned to
    /// `AfterFirstUnlockThisDeviceOnly` accessibility (device-bound, never iCloud-synced).
    ///
    /// - Returns: the `SecItemAdd` status, for the same reason the general overload does.
    public static func store(_ data: Data, for account: Account, service: String) -> OSStatus {
        store(data, account: account.rawValue, service: service,
              accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Loads the data stored for a well-known ``Account``, or `nil` when absent.
    public static func load(for account: Account, service: String) -> Data? {
        load(account: account.rawValue, service: service)
    }

    /// Deletes the item stored for a well-known ``Account``; a no-match is silently ignored.
    public static func delete(for account: Account, service: String) {
        delete(account: account.rawValue, service: service)
    }

    /// ``delete(for:service:)`` reporting its outcome, for the wipe flows that must know whether the
    /// row is genuinely gone (`errSecItemNotFound` normalized to `errSecSuccess`).
    public static func deleteReportingStatus(for account: Account, service: String) -> OSStatus {
        deleteReportingStatus(account: account.rawValue, service: service)
    }

    /// Loads the device-bound `SymmetricKey` stored for a well-known ``Account``, minting and
    /// persisting a fresh 256-bit key **only** when the keychain definitively reports the row absent.
    ///
    /// Goes through the typed ``store(_:for:service:)`` overload, so the row is pinned to
    /// `AfterFirstUnlockThisDeviceOnly` accessibility (device-bound, never iCloud-synced).
    ///
    /// R7: the read distinguishes absence from unreadability (``loadDistinguishingAbsence(account:service:synchronizable:)``)
    /// and BOTH failure legs are audited AND fail closed — `keychain.deviceKey.unreadable` when a
    /// read could not reach an existing row, and `keychain.deviceKey.storeFailed` when the fresh key
    /// could not be persisted.
    ///
    /// - Returns: The key, or nil when the row could not be read or the minted key could not be
    ///   stored. Nothing is cached and nothing is written in those cases, so callers fail closed and
    ///   the next access retries.
    /// - Important: the absent-vs-unreadable distinction is load-bearing, not cosmetic. A plain
    ///   "read failed ⇒ mint" would, during the window when the row exists but is unavailable (an
    ///   `AfterFirstUnlockThisDeviceOnly` item before the first post-boot unlock, or any transient
    ///   `SecItemCopyMatching` failure), mint a fresh key and — since ``store(_:account:service:accessibility:synchronizable:replacing:)``
    ///   is delete-then-add — REPLACE the real one, turning every sealed journal entry and Worry Box
    ///   row into permanent garbage with no failure signal. Fail closed instead: no key, no reads,
    ///   no writes, no mint, no delete — and the next attempt after unlock succeeds.
    public static func loadOrCreateSymmetricKey(for account: Account, service: String) -> SymmetricKey? {
        switch loadDistinguishingAbsence(account: account.rawValue, service: service) {
        case .found(let data):
            return SymmetricKey(data: data)
        case .unreadable(let status):
            FernletAuditLog.log("keychain.deviceKey.unreadable", context: [
                "account": account.rawValue, "status": "\(status)"
            ])
            // Load-bearing: returning here is what stops `store`'s delete-then-add from ever running
            // against a row we could not read.
            return nil
        case .absent:
            break
        }
        let key = SymmetricKey(size: .bits256)
        let status = store(key.rawBytes, for: account, service: service)
        guard status == errSecSuccess else {
            FernletAuditLog.log("keychain.deviceKey.storeFailed", context: [
                "account": account.rawValue, "status": "\(status)"
            ])
            // Never hand back a key that was not persisted: content sealed with it would be
            // unopenable next launch.
            return nil
        }
        return key
    }
}

nonisolated extension SymmetricKey {
    /// The key's raw material as an owned `Data` — the single CryptoKit byte-export seam in the
    /// shipping tree (Power-of-10 R9).
    ///
    /// `SymmetricKey` is not a `Sequence` and exposes its bytes only through `ContiguousBytes`'
    /// `withUnsafeBytes`; there is no `Data(key)` initialiser. Every store that has to hand key
    /// material to the data-protection keychain used to spell that borrow out itself, so the same
    /// unsafe idiom was repeated across four modules and needed four allowlist entries. It lives
    /// here once instead.
    ///
    /// Invariant that makes the seam safe: the borrowed buffer is copied into an owned `Data`
    /// *inside* the callback, so no pointer, buffer, or index escapes `withUnsafeBytes` and the
    /// buffer is never read after it returns.
    ///
    /// Callers hand the result straight to the keychain and do not retain it; a `Data` of key
    /// material is not zeroed on release, so never hold one longer than the write it feeds.
    ///
    /// `nonisolated`: a pure byte copy with no shared state, called from the `nonisolated`
    /// ``KeychainItem`` accessors and from sealed stores on any executor.
    public var rawBytes: Data {
        withUnsafeBytes { Data($0) }
    }
}
