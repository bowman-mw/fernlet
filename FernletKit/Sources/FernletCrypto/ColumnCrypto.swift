import CryptoKit
import Foundation

/// Shared ChaChaPoly column-encryption helper for the sealed private-store repositories.
///
/// Each repository creates one instance with its own typed HKDF purpose so journal, worry,
/// menstrual, and intimacy ciphertexts remain isolated even under the same content key.
/// Every call derives a per-column subkey from the caller-supplied content key via HKDF-SHA256
/// (with that purpose as the `info` input)
/// and seals or opens the value with ChaCha20-Poly1305, reading and writing the
/// sealed box's `combined` representation (nonce ‖ ciphertext ‖ tag) as one `Data` blob.
///
/// No key material is ever stored here: callers pass the content key per call, and
/// it originates from `FernletLockService` (the keychain-backed app lock in the
/// `FernletLock` module), which exposes it only while the private area is unlocked —
/// the repositories fail closed when it is `nil`. Because HKDF is deterministic,
/// the purpose is part of the at-rest format: changing a repository's purpose orphans
/// every ciphertext already sealed under the old purpose.
///
/// **At-rest format — ONE generation.** Every blob is `0x03`
/// (``deviceBoundFormatVersionV3``) followed by the sealed box's `combined` bytes, sealed
/// with this column's purpose ‖ this install's ``DeviceBindingID`` as ChaChaPoly additional
/// authenticated data — so the ciphertext refuses to authenticate on any other install, not
/// just under a different key. Both halves of the round's Phase 3 landed here: sealing
/// **refuses** when no binding ID is available
/// (``SealedColumnStrictSealError/bindingUnavailable``, owner decision D4) rather than
/// writing an un-domained blob, and opening reads V3 and nothing else.
///
/// Two earlier generations were readable until then — an unprefixed no-AAD blob (`legacy`) and
/// a `0x02` binding-only-AAD blob (`v2`) — and their rungs were deleted together with the
/// migrator that converted through them. Their bytes are still CLASSIFIED, by
/// ``ColumnCryptoStoredFormat``, so a refusal can name what it refused; they are simply no
/// longer opened. See ``SealedColumnOpenError``.
///
/// Explicitly `nonisolated` (overriding this module's MainActor default isolation):
/// it is a pure, stateless crypto value type called synchronously from the
/// `NSManagedObjectContext.performAndWait` closures of the (nonisolated) sealed-store
/// repositories, which under the package's Swift 6 language mode run in a nonisolated
/// context. MainActor isolation here would make those synchronous calls illegal.
/// `Sendable` for the same reason: `performAndWait` takes a `@Sendable` closure, and the
/// repositories that hold an instance are themselves `Sendable`; the only stored state is
/// the immutable typed purpose, so the conformance is compiler-checked, not `@unchecked`.
///
/// Failure modes: sealing rethrows CryptoKit errors, and throws
/// ``SealedColumnStrictSealError/bindingUnavailable`` when no durable install binding
/// exists (a save FAILS rather than degrading to an older format). Opening throws
/// ``SealedColumnOpenError`` — naming a retired format, an empty column, or an absent install
/// binding — when the bytes are not openable V3 at all, and a Poly1305 authentication failure
/// when a V3 blob is truncated, tampered with, or sealed under a different content key, label,
/// or install. One retryable exception: when the install-binding keychain read *errored* (as
/// opposed to the row being absent), the open throws `DeviceBindingID.ReadError` instead of
/// either — a transient keychain outage means "try again", not "data corrupted". The `Codable`
/// variants additionally rethrow JSON encoding/decoding errors.
public nonisolated struct ColumnCrypto: Sendable {
    /// Why a stored sealed-column blob could not be opened, **named by what the bytes are**.
    ///
    /// Phase 3 of the crypto standardization round left V3 as the only readable generation. The
    /// two rungs below it — the `0x02` binding-only open and the unconditional unprefixed no-AAD
    /// fallback — are gone, and with them the ability to open the bytes they read. What replaces
    /// them is this: a refusal that says *which* format it found, because "the bytes are V2 and
    /// this build only reads V3" is something a person can act on and "decryption failed" is not.
    ///
    /// Deliberately NOT thrown for a tampered or wrong-key V3 blob: that is a genuine
    /// authentication failure and CryptoKit's own error is the honest answer there. And
    /// deliberately NOT thrown when `DeviceBindingID.currentForOpen()` *errors* — that keeps
    /// throwing ``DeviceBindingID/ReadError``, which is retryable by contract, so a transient
    /// keychain outage never masquerades as "your data is in a dead format".
    ///
    /// `nonisolated` (overriding this module's MainActor default isolation) and `Sendable` for the
    /// same reason ``ColumnCrypto`` itself is: a pure value crossing `performAndWait` closures.
    public nonisolated enum SealedColumnOpenError: Error, Sendable, Equatable {
        /// The blob's marker byte says it is a generation this build no longer reads: `0x02`
        /// (device-bound v2, binding-only AAD) or no marker at all (the pre-binding legacy blob).
        /// Terminal — nothing here can open it, and no migrator can either, because the migrator
        /// converted THROUGH the rung that is gone.
        ///
        /// The classification is exact for ``ColumnCryptoStoredFormat/unprefixed`` and an upper
        /// bound for ``ColumnCryptoStoredFormat/v2Marked``: a V3 blob is never misreported, but a
        /// legacy blob whose random first nonce byte happened to equal `0x02` is reported as V2.
        /// Both readings mean the same thing to a caller — this build cannot open these bytes.
        case retiredFormat(ColumnCryptoStoredFormat)
        /// The column holds zero bytes. No writer produces `Data()` and every real sealed blob is
        /// at least nonce + tag, so this is a store fault rather than a format — Phase 2.6's
        /// "empty bytes are corruption" finding, kept as its own case so it can never be filed as
        /// a retired FORMAT and quietly counted with the legacy population.
        case emptyBlob
        /// The blob is V3 but the install binding its AAD needs is authoritatively ABSENT (not
        /// unreadable — that throws ``DeviceBindingID/ReadError``). The AAD cannot be
        /// reconstructed, so the blob cannot be opened on this install. Terminal, and distinct
        /// from an authentication failure: nothing is wrong with the ciphertext.
        case installBindingMissing
    }

    /// Refusal thrown by ``sealPlaintextV3Strict(_:contentKey:)`` — the ONE seal entry — when it
    /// cannot mint the device-bound v3 format.
    ///
    /// Until Phase 3 of the crypto standardization round this refusal was the strict *sibling's*
    /// alone, and the shipping writer fell open to an un-domained legacy blob in the same
    /// condition. Owner decision D4 closed that branch and the two entries collapsed into one, so
    /// this error now reaches every sealed-column writer.
    public nonisolated enum SealedColumnStrictSealError: Error, Equatable {
        /// `DeviceBindingID.current()` produced no durable install binding, so a V3 blob (whose
        /// AAD includes the binding) cannot be minted. The seal refuses; it never writes a legacy
        /// blob. Callers see a failed save — deliberately, because the alternative is a save that
        /// silently succeeds in a format the round exists to retire.
        case bindingUnavailable
    }

    /// HKDF `info` purpose that domain-separates this instance's derived column key
    /// from every other column sealed under the same content key.
    let purpose: CryptographicPurpose

    /// Version tag of the retired device-bound v2 blob (binding-only AAD). **A CLASSIFIER, not a
    /// reader** since Phase 3 deleted the v2 rung: nothing opens these bytes any more, and this
    /// constant survives only so ``ColumnCryptoStoredFormat`` can tell a caller *which* retired
    /// generation it is refusing. Changing it would silently reclassify every remaining v2 blob as
    /// unprefixed legacy — a worse refusal, not a broken one, but still a lie.
    static let deviceBoundFormatVersionV2: UInt8 = 0x02
    /// Version tag prefixed to every sealed blob this build writes or reads. Part of the at-rest
    /// format: changing it orphans every ciphertext already written, because the open path would
    /// stop recognizing the prefix and refuse the blob as a retired format.
    static let deviceBoundFormatVersionV3: UInt8 = 0x03

    /// Creates a helper bound to one reviewed column purpose.
    ///
    /// - Parameter purpose: The immutable HKDF purpose for this column.
    public init(purpose: CryptographicPurpose) {
        self.purpose = purpose
    }

    /// Test/fixture compatibility bridge for the four legacy labels. Production repositories use
    /// the typed initializer above; unknown labels deliberately fail closed instead of deriving a
    /// silently orphaned key.
    public init(label: String) {
        switch label {
        case FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1.rawValue:
            purpose = FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1
        case FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1.rawValue:
            purpose = FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1
        case FernletCryptoPurpose.KeyDerivation.menstrualNarrativeLegacyV1.rawValue:
            purpose = FernletCryptoPurpose.KeyDerivation.menstrualNarrativeLegacyV1
        case FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1.rawValue:
            purpose = FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1
        default:
            assertionFailure("Unknown legacy column purpose")
            purpose = FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1
        }
    }

    // MARK: - String

    /// Seals a string column as a ChaChaPoly `combined` blob under this column's derived key.
    ///
    /// - Parameters:
    ///   - value: The plaintext to encrypt (UTF-8 encoded before sealing).
    ///   - contentKey: The unlocked content key the column subkey is derived from.
    /// - Returns: One opaque blob suitable for a single binary Core Data attribute:
    ///   the device-bound v3 form (version byte ‖ nonce ‖ ciphertext ‖ tag, sealed
    ///   with the column purpose ‖ the install's binding ID as AAD).
    /// - Throws: ``SealedColumnStrictSealError/bindingUnavailable`` when no durable install
    ///   binding exists — there is no legacy fallback; otherwise rethrows CryptoKit seal errors.
    public func sealString(_ value: String, contentKey: SymmetricKey) throws -> Data {
        try sealPlaintextV3Strict(Data(value.utf8), contentKey: contentKey)
    }

    /// Seals an optional string column, skipping values with nothing to protect.
    ///
    /// Returns nil when value is nil or empty (nothing to seal).
    public func sealOptionalString(_ value: String?, contentKey: SymmetricKey) throws -> Data? {
        guard let value, !value.isEmpty else { return nil }
        return try sealString(value, contentKey: contentKey)
    }

    /// Opens a sealed string column back to plaintext.
    ///
    /// - Returns: `nil` when `data` is `nil` (the column was never sealed) or when
    ///   the decrypted bytes are not valid UTF-8; the plaintext string otherwise.
    /// - Important: Throws on authentication failure — a truncated or tampered blob,
    ///   or one sealed under a different content key or label.
    public func openString(_ data: Data?, contentKey: SymmetricKey) throws -> String? {
        guard let data else { return nil }
        let plaintext = try openBlob(data, contentKey: contentKey)
        return String(data: plaintext, encoding: .utf8)
    }

    // MARK: - Codable

    /// Seals any `Encodable` value by JSON-encoding it, then encrypting the JSON.
    ///
    /// Used by the repositories for structured columns stored alongside the string
    /// columns — journal emotion lists, menstrual symptom-flag arrays, and custom
    /// symptom scales. The plaintext uses default `JSONEncoder` settings, so it must
    /// be opened with the matching ``open(_:contentKey:)``.
    public func seal<T: Encodable>(_ value: T, contentKey: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(value)
        return try sealPlaintextV3Strict(plaintext, contentKey: contentKey)
    }

    /// Opens a sealed `Codable` column: decrypts, then JSON-decodes the plaintext.
    ///
    /// - Returns: `nil` when `data` is `nil` (the column was never sealed); the
    ///   decoded value otherwise.
    /// - Important: Throws on authentication failure or when the decrypted JSON
    ///   does not decode as `T`.
    public func open<T: Decodable>(_ data: Data?, contentKey: SymmetricKey) throws -> T? {
        guard let data else { return nil }
        let plaintext = try openBlob(data, contentKey: contentKey)
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    // MARK: - Device-bound format core

    /// THE one seal entry — every sealed-column write in the app, and the Phase 2.6 format
    /// migrator's re-seal, land here. Writes device-bound v3 and nothing else: `0x03` ‖
    /// `combined`, with the column purpose ‖ this install's ``DeviceBindingID`` as AAD.
    ///
    /// ## Why there is no lenient sibling any more
    ///
    /// Through Phase 2.6 this had a private twin, `sealPlaintext`, which *fell open*: with no
    /// durable binding it wrote an unprefixed, un-domained legacy blob rather than refusing, on the
    /// argument that binding is defense-in-depth and never a gate. `DeviceBindingID.current()`
    /// returns nil on any keychain read/add failure, and the binding row is
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — so the pre-first-unlock window alone
    /// could mint a fresh legacy blob on any shipping build, at any time. That branch is why every
    /// format-census zero was "a moment, not a latch". Phase 3 of
    /// `Docs/Plan-Crypto-Standardization-2026-08-27.md` closed it (owner decision D4: fail close),
    /// the two entries became byte-identical, and they were collapsed into this one so no third
    /// copy can grow. The cost is deliberate and accepted: a sealed save can now FAIL where it used
    /// to succeed in the wrong format.
    ///
    /// The `V3Strict` name is kept rather than renamed to `sealPlaintext`: it still says exactly
    /// what the method does — v3 or nothing — which is now the whole of the surface's format story
    /// on the write side and the read side alike.
    ///
    /// - Parameters:
    ///   - plaintext: The exact bytes to seal (byte-level — no UTF-8 or JSON semantics).
    ///   - contentKey: The unlocked content key the column subkey is derived from.
    /// - Returns: `0x03` ‖ `combined`, sealed with `purpose ‖ binding` as AAD.
    /// - Throws: ``SealedColumnStrictSealError/bindingUnavailable`` when no durable install
    ///   binding exists; otherwise rethrows CryptoKit seal errors.
    public func sealPlaintextV3Strict(_ plaintext: Data, contentKey: SymmetricKey) throws -> Data {
        let key = columnKey(from: contentKey)
        guard let binding = DeviceBindingID.current() else {
            throw SealedColumnStrictSealError.bindingUnavailable
        }
        let aad = purpose.data + binding
        let combined = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad).combined
        return Data([Self.deviceBoundFormatVersionV3]) + combined
    }

    /// Opens a sealed blob. **V3 is the only readable generation**: `0x03` ‖ `combined`,
    /// authenticated with `purpose ‖ binding` as AAD.
    ///
    /// ## What was deleted, and what took its place
    ///
    /// This used to be a three-rung ladder — try v3, then v2 (binding-only AAD), then fall back
    /// unconditionally to an unprefixed no-AAD open of the whole blob, which also disambiguated
    /// the rare legacy blob whose first ciphertext byte happened to equal a version tag. Phase 3
    /// of the crypto standardization round deleted the lower two rungs (the `legacy-read` hatch
    /// and the `v2 device-bound read` hatch, owner decision D2), leaving one at-rest format for
    /// this surface. Their healer went with them: `SealedColumnFormatMigrator` converted THROUGH
    /// this dispatch, so with the rungs gone it could no longer heal anything.
    ///
    /// Bytes those rungs used to open now throw ``SealedColumnOpenError/retiredFormat(_:)``,
    /// naming the generation the marker byte reports — the classifier
    /// (``ColumnCryptoStoredFormat``) OUTLIVES the reader precisely so the refusal can say what it
    /// refused.
    ///
    /// - Important: Three failures, deliberately kept apart. A **retired format**, an **empty
    ///   column**, or an **authoritatively absent install binding** each throw their own
    ///   ``SealedColumnOpenError`` case — terminal, and none of them an authentication claim. A
    ///   V3 blob that is truncated, tampered with, or sealed under a different content key or
    ///   install fails with CryptoKit's own authentication error, which is the honest answer
    ///   there. And when the install-binding keychain read *errors* — the row's state unknown, as
    ///   opposed to authoritatively absent — ``DeviceBindingID/ReadError`` propagates unchanged,
    ///   so a transient keychain outage still surfaces as "try again" and never as corrupted data.
    ///   That distinction was the reason `currentForOpen()` exists and it survives the deletion.
    private func openBlob(_ data: Data, contentKey: SymmetricKey) throws -> Data {
        let format = ColumnCryptoStoredFormat.classify(data)
        switch format {
        case .v3Marked:
            break
        case .empty:
            throw SealedColumnOpenError.emptyBlob
        case .v2Marked, .unprefixed:
            throw SealedColumnOpenError.retiredFormat(format)
        }
        // Outside any `try?`: a ReadError here means the binding row's state is UNKNOWN, and it
        // must reach the caller as itself rather than be flattened into an open failure.
        guard let binding = try DeviceBindingID.currentForOpen() else {
            throw SealedColumnOpenError.installBindingMissing
        }
        let key = columnKey(from: contentKey)
        let box = try ChaChaPoly.SealedBox(combined: data.dropFirst())
        return try ChaChaPoly.open(box, using: key, authenticating: purpose.data + binding)
    }

    // MARK: - Key derivation

    /// Derives a purpose-bound subkey from the content key via salt-free HKDF-SHA256,
    /// with the typed purpose as the domain-separating `info` input.
    ///
    /// This is THE column-key derivation every sealed ciphertext depends on: the purpose
    /// and the derivation are part of the at-rest format, so any change here orphans
    /// all existing sealed columns. Module-internal (least privilege, per the WI-7
    /// precedent) — production code reaches it only through the sealing methods above,
    /// while `FernletLockCryptoTests` characterizes it directly via
    /// `@testable import FernletCrypto`, including a pinned known-answer vector.
    ///
    /// - Parameters:
    ///   - contentKey: The unlocked content key used as the HKDF input key material.
    ///   - purpose: The typed domain-separation value (the HKDF `info` input, UTF-8 encoded).
    ///   - outputByteCount: The derived-key length in bytes (32 for ChaCha20 column keys).
    /// - Returns: The deterministically derived subkey.
    static func deriveColumnKey(
        contentKey: SymmetricKey,
        purpose: CryptographicPurpose,
        outputByteCount: Int
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, info: purpose.data, outputByteCount: outputByteCount)
    }

    static func deriveColumnKey(contentKey: SymmetricKey, info: String, outputByteCount: Int) -> SymmetricKey {
        let purpose = ColumnCrypto(label: info).purpose
        return deriveColumnKey(contentKey: contentKey, purpose: purpose, outputByteCount: outputByteCount)
    }

    // MARK: - Private

    /// Derives this column's 32-byte ChaCha20 subkey from the content key via
    /// ``deriveColumnKey(contentKey:purpose:outputByteCount:)``, using `purpose`
    /// as the domain-separating `info` input.
    private func columnKey(from contentKey: SymmetricKey) -> SymmetricKey {
        Self.deriveColumnKey(contentKey: contentKey, purpose: purpose, outputByteCount: 32)
    }
}
