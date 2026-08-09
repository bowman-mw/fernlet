import CryptoKit
import Foundation

/// Shared ChaChaPoly column-encryption helper for the sealed private-store repositories.
///
/// Each repository creates one instance with its own HKDF label so journal, worry,
/// menstrual, and intimacy ciphertexts remain isolated even under the same content
/// key: `JournalNarrativeRepository` ("journal-narrative") and `WorryNarrativeRepository`
/// ("worry-box") in `PrivateMemoryStore`, plus `MenstrualNarrativeRepository`
/// ("menstrual-narrative") and `IntimacyLogRepository` ("intimacy-log") in
/// `PrivateHealthStore`. Every call derives a per-column subkey from the
/// caller-supplied content key via HKDF-SHA256 (with `label` as the `info` input)
/// and seals or opens the value with ChaCha20-Poly1305, reading and writing the
/// sealed box's `combined` representation (nonce ‖ ciphertext ‖ tag) as one `Data` blob.
///
/// No key material is ever stored here: callers pass the content key per call, and
/// it originates from `FernletLockService` (the keychain-backed app lock in the
/// `FernletLock` module), which exposes it only while the private area is unlocked —
/// the repositories fail closed when it is `nil`. Because HKDF is deterministic,
/// the label is part of the at-rest format: changing a repository's label orphans
/// every ciphertext already sealed under the old label.
///
/// Explicitly `nonisolated` (overriding this module's MainActor default isolation):
/// it is a pure, stateless crypto value type called synchronously from the
/// `NSManagedObjectContext.performAndWait` closures of the (nonisolated) sealed-store
/// repositories, which under the package's Swift 6 language mode run in a nonisolated
/// context. MainActor isolation here would make those synchronous calls illegal.
///
/// Failure modes: sealing rethrows CryptoKit errors; opening throws when the blob is
/// truncated, tampered with, or sealed under a different content key or label
/// (Poly1305 authentication failure). The `Codable` variants additionally rethrow
/// JSON encoding/decoding errors.
public nonisolated struct ColumnCrypto {
    /// HKDF `info` string that domain-separates this instance's derived column key
    /// from every other column sealed under the same content key.
    let label: String

    /// Creates a helper bound to one column label.
    ///
    /// - Parameter label: The HKDF domain-separation label for this column
    ///   (e.g. "journal-narrative"). Must stay stable for the life of the data —
    ///   ciphertext sealed under one label cannot be opened under another.
    public init(label: String) {
        self.label = label
    }

    // MARK: - String

    /// Seals a string column as a ChaChaPoly `combined` blob under this column's derived key.
    ///
    /// - Parameters:
    ///   - value: The plaintext to encrypt (UTF-8 encoded before sealing).
    ///   - contentKey: The unlocked content key the column subkey is derived from.
    /// - Returns: The sealed box's combined representation (nonce ‖ ciphertext ‖ tag),
    ///   suitable for storage in a single binary Core Data attribute.
    public func sealString(_ value: String, contentKey: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(Data(value.utf8), using: columnKey(from: contentKey)).combined
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
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
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
        return try ChaChaPoly.seal(plaintext, using: columnKey(from: contentKey)).combined
    }

    /// Opens a sealed `Codable` column: decrypts, then JSON-decodes the plaintext.
    ///
    /// - Returns: `nil` when `data` is `nil` (the column was never sealed); the
    ///   decoded value otherwise.
    /// - Important: Throws on authentication failure or when the decrypted JSON
    ///   does not decode as `T`.
    public func open<T: Decodable>(_ data: Data?, contentKey: SymmetricKey) throws -> T? {
        guard let data else { return nil }
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    // MARK: - Key derivation

    /// Derives a purpose-bound subkey from the content key via salt-free HKDF-SHA256,
    /// with `info` as the domain-separating label.
    ///
    /// This is THE column-key derivation every sealed ciphertext depends on: the label
    /// and the derivation are part of the at-rest format, so any change here orphans
    /// all existing sealed columns. Module-internal (least privilege, per the WI-7
    /// precedent) — production code reaches it only through the sealing methods above,
    /// while `FernletLockCryptoTests` characterizes it directly via
    /// `@testable import FernletCrypto`, including a pinned known-answer vector.
    ///
    /// - Parameters:
    ///   - contentKey: The unlocked content key used as the HKDF input key material.
    ///   - info: The domain-separation label (the HKDF `info` input, UTF-8 encoded).
    ///   - outputByteCount: The derived-key length in bytes (32 for ChaCha20 column keys).
    /// - Returns: The deterministically derived subkey.
    static func deriveColumnKey(contentKey: SymmetricKey, info: String, outputByteCount: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, info: Data(info.utf8), outputByteCount: outputByteCount)
    }

    // MARK: - Private

    /// Derives this column's 32-byte ChaCha20 subkey from the content key via
    /// ``deriveColumnKey(contentKey:info:outputByteCount:)``, using `label`
    /// as the domain-separating `info` input.
    private func columnKey(from contentKey: SymmetricKey) -> SymmetricKey {
        Self.deriveColumnKey(contentKey: contentKey, info: label, outputByteCount: 32)
    }
}
