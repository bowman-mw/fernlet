import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import Security

/// The two device keys the World map's files are sealed under.
///
/// - **store**: `WhenUnlockedThisDeviceOnly`. The fog (and, in later steps, routes and pins) can only
///   be read or written while the phone is unlocked.
/// - **buffer**: `AfterFirstUnlockThisDeviceOnly`, for the small locked-phone buffer alone: a walk with
///   the screen off, or Always mode's visits, can lift cells while the phone is locked, and those wait
///   in the buffer until the next unlock drains them into the store. The same split as the
///   pending-narrative buffer (`PendingNarrativeBuffer`), and for the same reason: a background writer
///   genuinely exists, so only the buffer's key is relaxed, never the store's.
///
/// Neither key ever syncs or leaves this device. Both live under ``WorldMapVault/keychainService``, so
/// ``WorldMapVault/clearAll()`` removes them with one call.
public nonisolated enum WorldMapKeyRole: String, Sendable, CaseIterable {
    case store
    case buffer

    /// The keychain account the role's key lives under (a frozen token).
    var account: String {
        switch self {
        case .store: "storeKey"
        case .buffer: "bufferKey"
        }
    }

    /// The role's keychain accessibility class.
    var accessibility: CFString {
        self == .store ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
}

/// Where the vault's keys come from: the keychain in the app, plain memory in tests and previews.
public nonisolated struct WorldMapKeys: Sendable {
    /// The key for `role`, minting one when none exists yet; throws when the keychain cannot be read
    /// (never mints over a row it could not read).
    public let key: @Sendable (WorldMapKeyRole) throws -> SymmetricKey
    /// Removes every key; whether that worked.
    public let removeAll: @Sendable () -> Bool

    /// Keys from closures (tests inject failures this way).
    public init(key: @escaping @Sendable (WorldMapKeyRole) throws -> SymmetricKey,
                removeAll: @escaping @Sendable () -> Bool) {
        self.key = key
        self.removeAll = removeAll
    }

    /// The device keychain under `service`.
    public static func keychain(service: String) -> WorldMapKeys {
        WorldMapKeys(key: { role in try keychainKey(role, service: service) },
                     removeAll: {
                         let status = KeychainItem.deleteAllReportingStatus(service: service)
                         return status == errSecSuccess || status == errSecItemNotFound
                     })
    }

    /// Fresh keys held in memory for this process only (tests, previews, and the in-memory store a
    /// test-built `FernletStore` gets).
    public static func ephemeral() -> WorldMapKeys {
        let store = SymmetricKey(size: .bits256), buffer = SymmetricKey(size: .bits256)
        return WorldMapKeys(key: { $0 == .store ? store : buffer }, removeAll: { true })
    }

    /// Reads the role's key, or mints and stores one when the row is absent. An unreadable row (the
    /// phone is locked, or a transient keychain failure) throws: minting over it would replace the
    /// real key and turn the stored history into noise.
    private static func keychainKey(_ role: WorldMapKeyRole, service: String) throws -> SymmetricKey {
        switch KeychainItem.loadDistinguishingAbsence(account: role.account, service: service) {
        case .found(let data):
            guard data.count == 32 else { throw WorldMapVault.VaultError.keyMalformed }
            return SymmetricKey(data: data)
        case .unreadable:
            throw WorldMapVault.VaultError.keyUnavailable
        case .absent:
            let key = SymmetricKey(size: .bits256)
            let status = KeychainItem.store(key.rawBytes, account: role.account, service: service,
                                            accessibility: role.accessibility)
            guard status == errSecSuccess else { throw WorldMapVault.VaultError.keyUnavailable }
            return key
        }
    }
}

/// The device-only, encrypted home of the World map's location history (World build, branch
/// `world-ui`; World app plan step 5a), shaped like the watch build's planned `DeviceRouteStore`.
///
/// Every file is AES-GCM sealed under a this-device-only key (``WorldMapKeys``) with its own
/// authenticated purpose (`FernletCryptoPurpose.AEAD.worldMap…`), written with file protection
/// (complete for the store, until-first-unlock for the locked-phone buffer), and kept in a folder
/// excluded from device backup. Nothing here is synced, exported, shared, given to the AI, or written to
/// Apple Health, and nothing in `CloudKitSync`, `AIProviders`, `AIContext`, `FernletSocial` or
/// `FernletConnections` can import this module (the strict build fails them).
///
/// `clearAll()` is the wipe: Delete everything and the silent wipe reach it through `FernletStore`'s
/// funnel, and the recovery lock through its own purge hook.
@MainActor
public final class WorldMapVault {
    /// The keychain service both keys live under (a frozen token; listed in the wipe-coverage table).
    public nonisolated static let keychainService = "com.fernlet.world-map"
    /// The prefix every sealed file starts with, so a stray file is refused by name before decryption.
    nonisolated static let magic = Data("FWM1".utf8)
    /// The largest sealed file the vault reads (a full fog store is about 2 MB).
    nonisolated static let maxFileBytes = 8 * 1_024 * 1_024

    /// What can go wrong, by name.
    public enum VaultError: Error, Equatable {
        /// The keychain could not be read right now (the phone is locked, or a transient failure).
        case keyUnavailable
        /// A stored key is the wrong length; it can never have sealed anything.
        case keyMalformed
        /// The bytes are not a World map file, or were sealed under another purpose or key.
        case unopenable
        /// The file is larger than any file the vault writes.
        case tooLarge
    }

    /// One sealed file: its name and the purpose its bytes are bound to.
    public struct File: Sendable, Equatable {
        /// The file name inside the vault's folder.
        public let name: String
        /// The authenticated purpose the file is sealed under.
        public let purpose: CryptographicPurpose
        /// Which key seals it.
        public let role: WorldMapKeyRole
        /// Further authenticated data after the purpose (a walk line's workout id), so a file renamed to
        /// another of its kind never opens. Empty for the fog files, whose sealing it leaves unchanged.
        public let context: Data

        /// A file `name`, sealed under `purpose` with `role`'s key, bound to `context`.
        public init(name: String, purpose: CryptographicPurpose, role: WorldMapKeyRole, context: Data = Data()) {
            self.name = name
            self.purpose = purpose
            self.role = role
            self.context = context
        }

        /// The authenticated data the file is sealed with: the purpose, then the context.
        var authenticatedData: Data { purpose.data + context }

        /// The fog store.
        public static let fog = File(name: "fog.bin", purpose: FernletCryptoPurpose.AEAD.worldMapFogV1, role: .store)
        /// The locked-phone buffer of cells waiting to be merged into the fog.
        public static let pendingFog = File(name: "fog-pending.bin", purpose: FernletCryptoPurpose.AEAD.worldMapPendingV1, role: .buffer)
        /// "Where you've been" (`PlaceLogStore`): the 30-day timeline and Places you return to, sealed with
        /// the Private tab's hub key (never a vault key), so it opens only while Private is open.
        public static let places = File(name: "places.bin", purpose: FernletCryptoPurpose.AEAD.worldMapPlacesV1, role: .store)
        /// The places log's device side (`PlaceLogStore`): stops captured while Private is closed, waiting
        /// to be folded under the hub key, and the allowed places' points that background visits are
        /// matched against. Under the buffer key, because Always mode's visits arrive with the phone locked.
        public static let placesDevice = File(name: "places-device.bin", purpose: FernletCryptoPurpose.AEAD.worldMapPlacesDeviceV1,
                                              role: .buffer)
        /// Where each solo camera photo was taken (`PhotoPlaceStore`), by photo id.
        public static let photoPlaces = File(name: "photo-places.bin", purpose: FernletCryptoPurpose.AEAD.worldMapPhotoPlacesV1,
                                             role: .store)
    }

    /// The folder the files live in.
    public let directory: URL
    private let keys: WorldMapKeys

    /// A vault over `directory` with `keys`.
    public init(directory: URL, keys: WorldMapKeys) {
        self.directory = directory
        self.keys = keys
    }

    /// The app's vault: `Application Support/WorldMap`, keys in the device keychain. Opening it re-asserts
    /// the folder's backup exclusion when the folder is already there (``keepOutOfBackups(_:)``).
    public static func production() -> WorldMapVault {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let vault = WorldMapVault(directory: support.appendingPathComponent("WorldMap", isDirectory: true),
                                  keys: .keychain(service: keychainService))
        vault.reassertBackupExclusion()
        return vault
    }

    /// Re-sets the folder's backup exclusion if the folder exists (a missing folder gets it when created).
    /// A failure is logged, never fatal: the next write sets it again before anything new lands.
    public func reassertBackupExclusion() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try Self.keepOutOfBackups(directory)
        } catch {
            FernletAuditLog.log("worldMap.vault.backupFlagFailed")
        }
    }

    /// A vault in a fresh temporary folder with in-memory keys: tests, previews and a test-built store.
    public static func ephemeral() -> WorldMapVault {
        WorldMapVault(directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("WorldMap-\(UUID().uuidString)", isDirectory: true),
                      keys: .ephemeral())
    }

    /// The opened contents of `file`, or nil when it doesn't exist.
    public func read(_ file: File) throws -> Data? {
        try read(file, key: { try self.keys.key(file.role) })
    }

    /// The opened contents of `file` sealed with `key` rather than one of the vault's own: the Private
    /// tab's hub key for "Where you've been" (`PlaceLogStore`), which the vault never holds and the
    /// caller passes per call while the tab is open. Nil when the file doesn't exist.
    public func read(_ file: File, sealedWith key: SymmetricKey) throws -> Data? {
        try read(file, key: { key })
    }

    /// Seals `plaintext` and writes it to `file`, atomically, with the file's protection class.
    public func write(_ plaintext: Data, to file: File) throws {
        try write(plaintext, to: file, key: try keys.key(file.role))
    }

    /// Seals `plaintext` with `key` (the Private tab's hub key) instead of a vault key and writes it to
    /// `file`, with the file's protection class.
    public func write(_ plaintext: Data, to file: File, sealedWith key: SymmetricKey) throws {
        try write(plaintext, to: file, key: key)
    }

    /// Reads and opens `file` with the key `key` returns, asked for only once the file exists.
    private func read(_ file: File, key: () throws -> SymmetricKey) throws -> Data? {
        let url = directory.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sealed = try Data(contentsOf: url)
        guard sealed.count <= Self.maxFileBytes else { throw VaultError.tooLarge }
        guard sealed.starts(with: Self.magic) else { throw VaultError.unopenable }
        let resolved = try key()
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(Self.magic.count))
            return try AES.GCM.open(box, using: resolved, authenticating: file.authenticatedData)
        } catch {
            throw VaultError.unopenable
        }
    }

    /// Seals `plaintext` under `key` and writes it to `file`.
    private func write(_ plaintext: Data, to file: File, key: SymmetricKey) throws {
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: file.authenticatedData).combined else {
                throw VaultError.unopenable
            }
            sealed = Self.magic + combined
        } catch {
            throw VaultError.unopenable
        }
        guard sealed.count <= Self.maxFileBytes else { throw VaultError.tooLarge }
        try prepareDirectory()
        let protection: Data.WritingOptions = file.role == .store
            ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication
        try sealed.write(to: directory.appendingPathComponent(file.name), options: [.atomic, protection])
    }

    /// Removes `file`; whether it is gone.
    @discardableResult
    public func remove(_ file: File) -> Bool {
        let url = directory.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// The names of the vault's files that start with `prefix`, at most `limit` of them (a missing folder
    /// has none). Bounded: the folder is read once and the list cut at `limit`.
    public func fileNames(withPrefix prefix: String, limit: Int) throws -> [String] {
        guard limit > 0, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Array(names.lazy.filter { $0.hasPrefix(prefix) }.prefix(limit))
    }

    /// Deletes every World map file and both keys: the wipe. Whether everything is gone.
    public func clearAll() -> Bool {
        var removed = true
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { removed = false }
        }
        let keysRemoved = keys.removeAll()
        FernletAuditLog.log("worldMap.vault.cleared", context: ["files": "\(removed)", "keys": "\(keysRemoved)"])
        return removed && keysRemoved
    }

    /// Creates the folder if needed and keeps it out of device backups — on every write, not only when it
    /// creates the folder (round 6b): a folder made by an older build, restored, or whose flag something
    /// cleared gets it back before anything new is written into it. Idempotent.
    private func prepareDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Self.keepOutOfBackups(directory)
    }

    /// Sets `isExcludedFromBackup` on `folder` unless it already carries it. Every write and the app's vault
    /// at launch (``production()``) call it, so "never in a backup" holds for a folder whatever made it.
    nonisolated static func keepOutOfBackups(_ folder: URL) throws {
        var target = folder
        target.removeAllCachedResourceValues()
        guard try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
