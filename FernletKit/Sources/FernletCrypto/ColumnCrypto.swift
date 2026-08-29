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
/// **At-rest format (two coexisting generations).** *Legacy:* the sealed box's raw
/// `combined` bytes, no AAD. *Device-bound v2* (all new writes when a binding ID is
/// available): a ``deviceBoundFormatVersion`` prefix byte followed by `combined`,
/// sealed with this install's ``DeviceBindingID`` as ChaChaPoly additional
/// authenticated data — so the ciphertext itself refuses to authenticate on any
/// other install, not just under a different key. Opens are dual-path: a
/// v2-prefixed blob is tried with the AAD first, then every blob falls back to the
/// legacy no-AAD open (which also disambiguates the 1-in-256 legacy blob whose
/// first ciphertext byte happens to equal the version tag). Legacy rows are
/// progressively rebound because every routine re-seal — edits, the
/// device-key→user-key migration at lock setup, period restore-on-unhide — writes
/// v2. When no binding ID is available, sealing **refuses**: it throws
/// ``SealedColumnStrictSealError/bindingUnavailable`` rather than writing an
/// un-domained legacy blob (the write-side fail-close of the crypto
/// standardization round's Phase 3 — see ``sealPlaintextV3Strict(_:contentKey:)``).
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
/// exists (a save FAILS rather than degrading to the legacy format); opening throws when the blob is
/// truncated, tampered with, or sealed under a different content key or label
/// (Poly1305 authentication failure). One retryable exception: when a v2-tagged blob
/// cannot be opened because the install-binding keychain read *errored* (as opposed
/// to the row being absent), the open throws `DeviceBindingID.ReadError` instead of
/// an authentication failure — a transient keychain outage means "try again", not
/// "data corrupted". The `Codable` variants additionally rethrow JSON
/// encoding/decoding errors.
public nonisolated struct ColumnCrypto: Sendable {
    /// Which branch of the shipping reader's dispatch actually opened a stored blob — the receipt
    /// ``openReportingRung(_:contentKey:)`` returns beside the plaintext, so the Phase 2.6 format
    /// migrator can tally *proven-by-open* generations instead of trusting marker bytes.
    ///
    /// `nonisolated` (overriding this module's MainActor default isolation) and `Sendable` for the
    /// same reason ``ColumnCrypto`` itself is: a pure value crossing `performAndWait` closures.
    public nonisolated enum SealedColumnOpenRung: Sendable, Equatable {
        /// The `0x03` branch: purpose + binding AAD authenticated.
        case v3
        /// The `0x02` branch: binding-only AAD authenticated.
        case v2
        /// The unconditional no-AAD fallback. `markerCollision` is non-nil when the first byte was
        /// `0x03`/`0x02` and the marked attempt failed — the 1-in-256 collided-sliver legacy blob,
        /// now proven legacy *by open* rather than inferred from a byte.
        case legacy(markerCollision: ColumnCryptoStoredFormat?)
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

    /// Version tag prefixed to device-bound (v2) sealed blobs. Part of the at-rest
    /// format: changing it orphans every v2 ciphertext already written (the open path
    /// would stop recognizing the prefix and misparse the blob as legacy).
    static let deviceBoundFormatVersionV2: UInt8 = 0x02
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
    /// The `V3Strict` name is kept rather than renamed to `sealPlaintext`: it is public API the
    /// migrator calls, and it still says exactly what the method does — v3 or nothing.
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

    /// Opens a sealed blob of every at-rest generation: tries device-bound v3 (purpose + binding),
    /// then v2 (binding only), then falls back to the legacy no-AAD open of the whole blob.
    /// This keeps every
    /// pre-binding row readable AND resolves the rare legacy blob whose first
    /// ciphertext byte happens to equal the version tag.
    ///
    /// - Important: Throws on authentication failure in *both* paths — a truncated or
    ///   tampered blob, one sealed under a different content key or label, or a v2
    ///   blob sealed by a different install (its AAD cannot be reproduced here). One
    ///   distinct, retryable case: when the blob is version-tagged, the install-binding
    ///   keychain read *errors* (`DeviceBindingID.ReadError` — the row's state is
    ///   unknown, as opposed to authoritatively absent), and the legacy fallback cannot
    ///   open the blob either, that read error is rethrown in place of the fallback's
    ///   authentication error — so a transient keychain outage surfaces as "try again",
    ///   never as corrupted data, matching the seal path's graceful degradation.
    ///
    /// Implemented as `openReportingRung(...).plaintext`, so the reader and the Phase 2.6
    /// migrator run ONE dispatch that cannot fork.
    private func openBlob(_ data: Data, contentKey: SymmetricKey) throws -> Data {
        try openReportingRung(data, contentKey: contentKey).plaintext
    }

    /// ``openBlob(_:contentKey:)`` with a receipt: same dispatch, same unconditional legacy
    /// fallback, same `ReadError` precedence — this IS the shipping reader's dispatch (`openBlob`
    /// delegates here), returning which rung actually authenticated the blob. The Phase 2.6
    /// migrator opens every stored blob through this so its tallies are *proven-by-open*, the
    /// keyed second witness that resolves the census's 1-in-256 collided marker sliver.
    ///
    /// - Returns: The plaintext plus the ``SealedColumnOpenRung`` that opened it.
    /// - Throws: Exactly what `openBlob` throws — an authentication failure when no rung opens
    ///   the blob, with `DeviceBindingID.ReadError` taking precedence when a version-tagged
    ///   blob's binding read errored and the legacy fallback failed too.
    public func openReportingRung(
        _ data: Data,
        contentKey: SymmetricKey
    ) throws -> (plaintext: Data, rung: SealedColumnOpenRung) {
        let key = columnKey(from: contentKey)
        var bindingReadError: (any Error)?
        if data.first == Self.deviceBoundFormatVersionV3 {
            do {
                if let binding = try DeviceBindingID.currentForOpen(),
                   let box = try? ChaChaPoly.SealedBox(combined: data.dropFirst()),
                   let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: purpose.data + binding) {
                    return (plaintext, .v3)
                }
            } catch {
                bindingReadError = error
            }
        }
        if data.first == Self.deviceBoundFormatVersionV2 {
            do {
                if let binding = try DeviceBindingID.currentForOpen(),
                   let box = try? ChaChaPoly.SealedBox(combined: data.dropFirst()),
                   let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: binding) { // cryptographic-domain: v2 device-bound read
                    return (plaintext, .v2)
                }
            } catch {
                bindingReadError = error
            }
        }
        do {
            let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key) // cryptographic-domain: legacy-read
            let marker = ColumnCryptoStoredFormat.classify(data)
            return (plaintext, .legacy(markerCollision: marker.isMarkerAmbiguous ? marker : nil))
        } catch {
            throw bindingReadError ?? error
        }
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
