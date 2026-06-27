import CryptoKit
import Foundation

// Shared ChaChaPoly column-encryption helper for private-store repositories.
// Each repository creates one instance with its own HKDF label so journal,
// menstrual, and intimacy ciphertexts remain isolated even under the same content key.
//
// Explicitly `nonisolated` (overriding this module's MainActor default isolation):
// it is a pure, stateless crypto value type called synchronously from the
// `NSManagedObjectContext.performAndWait` closures of the (nonisolated) sealed-store
// repositories, which under the package's Swift 6 language mode run in a nonisolated
// context. MainActor isolation here would make those synchronous calls illegal.
public nonisolated struct ColumnCrypto {
    let label: String

    public init(label: String) {
        self.label = label
    }

    // MARK: - String

    public func sealString(_ value: String, contentKey: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(Data(value.utf8), using: columnKey(from: contentKey)).combined
    }

    /// Returns nil when value is nil or empty (nothing to seal).
    public func sealOptionalString(_ value: String?, contentKey: SymmetricKey) throws -> Data? {
        guard let value, !value.isEmpty else { return nil }
        return try sealString(value, contentKey: contentKey)
    }

    public func openString(_ data: Data?, contentKey: SymmetricKey) throws -> String? {
        guard let data else { return nil }
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
        return String(data: plaintext, encoding: .utf8)
    }

    // MARK: - Codable

    public func seal<T: Encodable>(_ value: T, contentKey: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(value)
        return try ChaChaPoly.seal(plaintext, using: columnKey(from: contentKey)).combined
    }

    public func open<T: Decodable>(_ data: Data?, contentKey: SymmetricKey) throws -> T? {
        guard let data else { return nil }
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    // MARK: - Private

    private func columnKey(from contentKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, info: Data(label.utf8), outputByteCount: 32)
    }
}
