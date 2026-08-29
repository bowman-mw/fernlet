import Foundation
import CryptoKit
import Security
import Testing
import FernletDomainModel
import FernletFoundation
@testable import FernletCrypto
@testable import FernletLock
@testable import Fernlet

@Suite(.serialized)
struct FernletLockCryptoTests {
    private let saltA = Data((0..<FernletLockCrypto.saltLength).map { UInt8($0) })
    private let saltB = Data((0..<FernletLockCrypto.saltLength).map { UInt8($0 + 16) })

    // MARK: Proves Scrypt verifier derivation is deterministic for identical inputs.
    @Test func verifierKDFDeterminism() async throws {
        let first = try await verifier(passcode: "123456", salt: saltA)
        let second = try await verifier(passcode: "123456", salt: saltA)
        #expect(first == second)
    }

    // MARK: Proves Scrypt cost parameters cannot be silently weakened.
    @Test func verifierKDFCostParametersAreEnforced() {
        #expect(FernletLockCrypto.scryptN >= 65536, "Scrypt N must be at least 65536 (2^16) per OWASP 2024+ guidance")
        #expect(FernletLockCrypto.scryptR >= 8, "Scrypt r must remain at least 8 for the lock verifier")
        #expect(FernletLockCrypto.scryptP >= 1, "Scrypt p must remain at least 1 for the lock verifier")
    }

    // MARK: Proves verifier derivation is salt-sensitive.
    @Test func verifierKDFSaltSensitivity() async throws {
        let first = try await verifier(passcode: "123456", salt: saltA)
        let second = try await verifier(passcode: "123456", salt: saltB)
        #expect(first != second)
    }

    // MARK: Proves one-character passcode changes avalanche across the verifier.
    @Test func verifierKDFPasscodeSensitivity() async throws {
        let first = try await verifier(passcode: "123456", salt: saltA)
        let second = try await verifier(passcode: "123457", salt: saltA)
        #expect(hammingDistance(first, second) > 100)
    }

    // MARK: Proves verifier output stays 32 bytes for the SHA-256-sized wrapping key.
    @Test func verifierKDFOutputLength() async throws {
        let derivedVerifier = try await verifier(passcode: "123456", salt: saltA)
        #expect(derivedVerifier.count == 32)
    }

    // MARK: Proves empty passcodes are handled deterministically by the primitive.
    @Test func verifierKDFEmptyPasscodeIsDeterministic() async throws {
        let first = try await verifier(passcode: "", salt: saltA)
        let second = try await verifier(passcode: "", salt: saltA)
        #expect(first == second)
    }

    // MARK: Proves maximum-length alphanumeric passcodes hash without truncation or failure.
    @Test func verifierKDFLongAlphanumericPasscodeHashes() async throws {
        let passcode = String(repeating: "Ab3", count: 21) + "Z"
        #expect(passcode.count == 64)
        let derivedVerifier = try await verifier(passcode: passcode, salt: saltA)
        #expect(derivedVerifier.count == FernletLockCrypto.keyLength)
    }

    // MARK: Proves Unicode passcodes use Swift UTF-8 bytes as-is without hidden normalization.
    @Test func verifierKDFUnicodePasscodeUsesUTF8BytesAsIs() async throws {
        let composed = "café🔒"
        let decomposed = "cafe\u{0301}🔒"
        let first = try await verifier(passcode: composed, salt: saltA)
        let second = try await verifier(passcode: composed, salt: saltA)
        let decomposedVerifier = try await verifier(passcode: decomposed, salt: saltA)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        #expect(first == second)
        #expect(first != decomposedVerifier)
    }

    // MARK: Proves generated salts are exactly 16 bytes.
    @Test func generatedSaltLength() throws {
        let salt = try FernletLockCrypto.generateSalt()
        #expect(salt.count == 16)
    }

    // MARK: Proves salt generation uses a CSPRNG with no repeated values in a small sample.
    @Test func generatedSaltEntropyProducesUniqueValues() throws {
        // FernletLockCrypto.generateSalt uses SecRandomCopyBytes(kSecRandomDefault), a system CSPRNG, not CryptoSwift AES.randomIV.
        let salts = try (0..<100).map { _ in try FernletLockCrypto.generateSalt().hexString }
        #expect(Set(salts).count == salts.count)
    }

    // MARK: Proves content-key wrapping round-trips through ChaChaPoly.
    @Test func aeadContentKeyWrapRoundTrip() async throws {
        let contentKey = randomData(count: 32)
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        let wrapped = try FernletLockCrypto.wrapContentKey(contentKey, using: wrappingKey)
        let unwrapped = try FernletLockCrypto.unwrapContentKey(wrapped, using: wrappingKey)
        #expect(unwrapped == contentKey)
    }

    // MARK: Proves ChaChaPoly refuses to unwrap with the wrong key.
    @Test func aeadWrongKeyFails() async throws {
        let contentKey = randomData(count: 32)
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        let wrongKey = try await verifier(passcode: "123457", salt: saltA)
        let wrapped = try FernletLockCrypto.wrapContentKey(contentKey, using: wrappingKey)
        #expect(throws: Error.self) {
            _ = try FernletLockCrypto.unwrapContentKey(wrapped, using: wrongKey)
        }
    }

    // MARK: Proves ChaChaPoly authenticates ciphertext bytes.
    @Test func aeadTamperedCiphertextFails() async throws {
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        var wrapped = try FernletLockCrypto.wrapContentKey(randomData(count: 32), using: wrappingKey)
        wrapped[FernletLockCrypto.aeadNonceLength + 4] ^= 0x01
        #expect(throws: Error.self) {
            _ = try FernletLockCrypto.unwrapContentKey(wrapped, using: wrappingKey)
        }
    }

    // MARK: Proves ChaChaPoly authenticates nonce bytes.
    //
    // The index is `markerLength + 0`, not `0`. Byte 0 is the `FLW2` format marker's first byte,
    // and flipping it exercises the FORMAT refusal instead of the AEAD — which is a different
    // property, already pinned by `retiredUnprefixedWrapIsRefusedByName`. A tamper test that
    // silently starts asserting the wrong mechanism still passes, which is the whole hazard.
    @Test func aeadTamperedNonceFails() async throws {
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        var wrapped = try FernletLockCrypto.wrapContentKey(randomData(count: 32), using: wrappingKey)
        wrapped[FernletLockCrypto.wrappedContentKeyFormatV2.count] ^= 0x01
        #expect(throws: Error.self) {
            _ = try FernletLockCrypto.unwrapContentKey(wrapped, using: wrappingKey)
        }
    }

    // MARK: Proves the retired UNPREFIXED wrap — the pre-domain generation whose reader was this
    // module's last `legacy-read` escape hatch — is refused BY NAME rather than degrading into an
    // authentication error that reads as "your sealed data is corrupt".
    //
    // The fixture is hand-built because production can no longer make one: `wrapContentKey` has
    // stamped `FLW2` since the domain split, so without this the refusal would be unreachable code.
    // Sealed under the CORRECT wrapping key on purpose — a refusal that only happened because the
    // key was wrong would prove nothing about the format.
    @Test func retiredUnprefixedWrapIsRefusedByName() async throws {
        let contentKey = randomData(count: 32)
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        let legacy = try ChaChaPoly.seal(contentKey, using: SymmetricKey(data: wrappingKey)).combined
        #expect(!legacy.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2))
        #expect(throws: FernletLockError.contentKeyWrapFormatRetired) {
            _ = try FernletLockCrypto.unwrapContentKey(legacy, using: wrappingKey)
        }
        // An empty row and a too-short row are the same refusal: whatever they are, they are not
        // `FLW2`, and the reader must not reach a `SealedBox(combined:)` that would throw something
        // shapeless instead.
        #expect(throws: FernletLockError.contentKeyWrapFormatRetired) {
            _ = try FernletLockCrypto.unwrapContentKey(Data(), using: wrappingKey)
        }
        #expect(throws: FernletLockError.contentKeyWrapFormatRetired) {
            _ = try FernletLockCrypto.unwrapContentKey(Data("FLW".utf8), using: wrappingKey)
        }
    }

    // MARK: Proves ChaChaPoly authenticates the final 16-byte tag.
    @Test func aeadTamperedAuthTagFails() async throws {
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        var wrapped = try FernletLockCrypto.wrapContentKey(randomData(count: 32), using: wrappingKey)
        wrapped[wrapped.count - 1] ^= 0x01
        #expect(throws: Error.self) {
            _ = try FernletLockCrypto.unwrapContentKey(wrapped, using: wrappingKey)
        }
    }

    // MARK: Proves different plaintext content keys produce different wrapped outputs.
    @Test func aeadDifferentPlaintextsProduceDifferentCiphertexts() async throws {
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        let first = try FernletLockCrypto.wrapContentKey(Data(repeating: 0x11, count: 32), using: wrappingKey)
        let second = try FernletLockCrypto.wrapContentKey(Data(repeating: 0x22, count: 32), using: wrappingKey)
        #expect(first != second)
    }

    // MARK: Proves the same plaintext is wrapped with a fresh nonce each time.
    @Test func aeadSamePlaintextProducesDifferentCiphertexts() async throws {
        let contentKey = randomData(count: 32)
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        let first = try FernletLockCrypto.wrapContentKey(contentKey, using: wrappingKey)
        let second = try FernletLockCrypto.wrapContentKey(contentKey, using: wrappingKey)
        #expect(first != second)
    }

    // MARK: Proves the wrapped ChaChaPoly body begins with unique 12-byte nonces — read AFTER the
    // `FLW2` marker, which is what the at-rest layout actually is (marker ‖ nonce ‖ ct ‖ tag).
    @Test func aeadNonceLengthAndUniqueness() async throws {
        let wrappingKey = try await verifier(passcode: "123456", salt: saltA)
        let nonces = try (0..<10).map { _ in
            let wrapped = try FernletLockCrypto.wrapContentKey(randomData(count: 32), using: wrappingKey)
            return wrapped
                .dropFirst(FernletLockCrypto.wrappedContentKeyFormatV2.count)
                .prefix(FernletLockCrypto.aeadNonceLength)
                .hexString
        }
        #expect(FernletLockCrypto.aeadNonceLength == 12)
        #expect(Set(nonces).count == nonces.count)
    }

    // MARK: Proves distinct HKDF info labels derive distinct column keys.
    //
    // Both labels are REAL columns. The second used to be an invented `"menstrual-symptoms"`, which
    // worked while the `info:` bridge passed any string straight to HKDF; the typed-purpose round
    // narrowed it to the four reviewed labels and made anything else fail closed, so an invented
    // label now asserts nothing (it resolves to the journal purpose behind an assertion failure).
    // Two real labels are also the stronger statement: distinctness matters precisely because these
    // two corpora are sealed side by side under one content key.
    @Test func hkdfDifferentInfoLabelsProduceDifferentKeys() {
        let contentKey = randomData(count: 32)
        let narrative = derivedColumnKeyData(contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 32)
        let intimacy = derivedColumnKeyData(contentKey: contentKey, info: "intimacy-log", outputByteCount: 32)
        #expect(narrative != intimacy)
    }

    // MARK: Proves HKDF derivation is deterministic for the same content key and label.
    @Test func hkdfSameInfoIsDeterministic() {
        let contentKey = randomData(count: 32)
        let first = derivedColumnKeyData(contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 32)
        let second = derivedColumnKeyData(contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 32)
        #expect(first == second)
    }

    // MARK: Proves HKDF output changes when the root content key changes.
    @Test func hkdfWrongContentKeyProducesDifferentOutput() {
        let first = derivedColumnKeyData(contentKey: Data(repeating: 0x11, count: 32), info: "menstrual-narrative", outputByteCount: 32)
        let second = derivedColumnKeyData(contentKey: Data(repeating: 0x22, count: 32), info: "menstrual-narrative", outputByteCount: 32)
        #expect(first != second)
    }

    // MARK: Proves HKDF honors 32-byte and 16-byte output lengths.
    @Test func hkdfOutputLengthMatchesRequest() {
        let contentKey = randomData(count: 32)
        let long = derivedColumnKeyData(contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 32)
        let short = derivedColumnKeyData(contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 16)
        #expect(long.count == 32)
        #expect(short.count == 16)
    }

    // MARK: Pins the production column-key derivation to a known-answer vector (RFC 5869
    // HKDF-SHA256, empty salt, info = label). Any drift in ColumnCrypto's derivation —
    // algorithm, salt, or info encoding — fails here loudly, because that drift would
    // orphan every ciphertext already sealed at rest.
    @Test func hkdfKnownAnswerVectorIsPinned() {
        let contentKey = Data((0..<32).map { UInt8($0) })
        let derived = derivedColumnKeyData(contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 32)
        #expect(derived.hexString == "e525a75bfcc621ea814161b685f4c637fbde3a8d1f88e5e1fce715aba7f95732")
    }

    // MARK: Pins the production column-key derivation for ALL FOUR sealed-column labels in use
    // (journal-narrative, worry-box, menstrual-narrative, intimacy-log — the ColumnCrypto
    // instances in PrivateMemoryStore/PrivateHealthStore). The labels + derivation ARE the
    // at-rest format: a drift in any one silently orphans that column's entire sealed corpus,
    // so each label gets its own known-answer vector (Docs/Verifiability.md §2).
    @Test func hkdfKnownAnswerVectorsArePinnedForAllFourColumnLabels() {
        let contentKey = Data((0..<32).map { UInt8($0) })
        let pinned: [(label: String, hex: String)] = [
            ("journal-narrative", "7ea257bf471a6fe1bd379bd4ae37bf69d8c2c82e27f686d4733da9f8652ecccd"),
            ("worry-box", "7f5b879410951d67685cf4b6a1f97617b831c708ac40acf15a48bb4d84d1ac2f"),
            ("menstrual-narrative", "e525a75bfcc621ea814161b685f4c637fbde3a8d1f88e5e1fce715aba7f95732"),
            ("intimacy-log", "e33e6039dbb78b152d763c7d4e3b3d22752dda9d7d59779e2fea2d12f1225fb8")
        ]
        for vector in pinned {
            let derived = derivedColumnKeyData(contentKey: contentKey, info: vector.label, outputByteCount: 32)
            #expect(derived.hexString == vector.hex, "column-key derivation drifted for label '\(vector.label)'")
        }
    }

    // MARK: Proves verifier comparison does not use plain Data equality.
    @Test func verifierComparisonIsConstantTime() throws {
        let source = try String(contentsOf: lockServiceSourceURL(), encoding: .utf8)
        let usesPlainEquals = source.contains("verifier ==") || source.contains("== verifier")
        #expect(usesPlainEquals == false, "verifier should use constant-time comparison")
        #expect(source.contains("constantTimeEqual(computedVerifier, storedVerifier)"))
        #expect(!source.contains("memcmp"), "memcmp is not a constant-time verifier comparison")
    }

    // MARK: Proves lock clears the in-memory SymmetricKey reference.
    @MainActor
    @Test func contentKeyScrubsOnLock() async throws {
        let service = freshService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
        service.lock(reason: .manual)
        #expect(service.contentKey(for: .privateHub) == nil, "Fernlet stores the content key as SymmetricKey and scrubs it by dropping the reference on lock")
        try? service.reset()
    }

    // MARK: Proves failed unlock does not leave plaintext content key accessible.
    @MainActor
    @Test func failedUnlockDoesNotLeavePlaintext() async throws {
        let service = freshService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let originalContentKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        service.lock(reason: .manual)

        do {
            _ = try await service.unlock(passcode: "999999", for: .privateHub)
            Issue.record("Wrong passcode unexpectedly unlocked the service")
        } catch FernletLockError.invalidPasscode { }

        #expect(service.contentKey(for: .privateHub) == nil)
        #expect(loadKeychainData(account: "com.fernlet.lock.biometricBypass", service: service.keychainService) == nil)
        // Whichever custody state this hardware lands in, the stored wrap must not BE the key:
        // hard-bound (SE hardware) leaves only the enclave blob, legacy leaves the scrypt item.
        if let wrappedContentKey = loadKeychainData(account: "com.fernlet.lock.wrappedContentKey", service: service.keychainService) {
            #expect(wrappedContentKey != originalContentKey)
        } else {
            let seWrapped = try #require(loadKeychainData(account: "com.fernlet.lock.seWrappedContentKey", service: service.keychainService),
                                         "hard-bound (no scrypt item) requires the enclave wrap to exist")
            #expect(seWrapped != originalContentKey)
        }
        try? service.reset()
    }

    // MARK: Proves the stored verifier is the DIGEST of the derived key, not the derived (wrapping) key
    // itself — so a keychain reader cannot use it to unwrap the content key (verifier/wrapping-key split).
    ///
    /// Runs against a deliberately LEGACY service (enclave-wrap persistence refused) so the pin is
    /// unconditional. On enclave hardware `configure()` is born hard-bound and deletes the scrypt
    /// item, which would leave the two load-bearing assertions — the stored verifier must NOT
    /// unwrap the persisted item, the raw derived key MUST — running only on SE-less hosts. The
    /// at-rest FORMAT is unchanged by P4; only this fixture is (see
    /// Docs/Plan-Security-Hardening-OpusTrack-2026-08-10.md §9). The hard-bound state gets its own
    /// pin in `hardBoundConfigureLeavesNoPasscodeDerivedRowThatOpensTheKey`, so both states are
    /// pinned on every host instead of one state per host.
    @MainActor
    @Test func configuredVerifierIsDigestNotWrappingKey() async throws {
        let service = freshService(persistEnclaveWrap: false)
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let salt = try #require(loadKeychainData(account: "com.fernlet.lock.salt", service: service.keychainService))
        let storedVerifier = try #require(loadKeychainData(account: "com.fernlet.lock.verifier", service: service.keychainService))
        let derivedKey = try await verifier(passcode: "123456", salt: salt)
        // Stored verifier == the domain-separated digest of derivedKey, and crucially != the raw
        // derived key (the wrapping key).
        #expect(storedVerifier == FernletLockCrypto.verifierDigest(of: derivedKey))
        // Specifically the v2 digest — NOT the bare `SHA256(derivedKey)` that `legacyVerifierDigest`
        // still computes for the one-time migration gate. A fresh configure must never write the
        // pre-domain-separation form, or the gate would keep re-migrating current installs.
        #expect(storedVerifier != FernletLockCrypto.legacyVerifierDigest(of: derivedKey))
        #expect(storedVerifier != derivedKey)

        // The persisted wrap is what this pins, in the state where a scrypt wrap exists at all.
        let wrapped = try #require(loadKeychainData(account: "com.fernlet.lock.wrappedContentKey", service: service.keychainService),
                                   "the forced-legacy fixture must have persisted the scrypt wrap")
        // The stored verifier must NOT unwrap the content key — that requires the raw derived key.
        #expect(throws: (any Error).self) {
            _ = try FernletLockCrypto.unwrapContentKey(wrapped, using: storedVerifier)
        }
        // ...whereas the raw derived key DOES unwrap it (proving the digest is the only thing persisted).
        let unwrapped = try FernletLockCrypto.unwrapContentKey(wrapped, using: derivedKey)
        #expect(unwrapped.count == FernletLockCrypto.keyLength)
        try? service.reset()
    }

    // MARK: Proves the complementary HARD-BOUND pin on enclave hardware: after the real
    // `configure()` no passcode-derived row survives that opens the content key at all — the
    // scrypt item is gone and only the enclave wrap remains. The SE-less branch asserts the
    // opposite property (the install stays legacy and keeps its scrypt row), so between this test
    // and `configuredVerifierIsDigestNotWrappingKey` both custody states are pinned on every host.
    @MainActor
    @Test func hardBoundConfigureLeavesNoPasscodeDerivedRowThatOpensTheKey() async throws {
        let service = freshService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        defer { try? service.reset() }
        let scryptRow = loadKeychainData(account: "com.fernlet.lock.wrappedContentKey", service: service.keychainService)
        let enclaveRow = loadKeychainData(account: "com.fernlet.lock.seWrappedContentKey", service: service.keychainService)

        if FernletLockService.isSecureEnclaveBindingAvailable {
            #expect(scryptRow == nil, "configure() on enclave hardware must be born hard-bound")
            #expect(enclaveRow != nil, "hard-bound requires the enclave wrap to exist")
        } else {
            #expect(scryptRow != nil, "SE-less hardware must stay legacy")
            #expect(enclaveRow == nil)
        }
    }

    /// A lock service on an isolated keychain slot. `persistEnclaveWrap: false` refuses the
    /// enclave-wrap write (reporting success and dropping it, so `storeVerified`'s read-back fails
    /// exactly as a hosed keychain would), which is the only way to hold enclave hardware in the
    /// LEGACY state — `configure()` otherwise hard-binds and deletes the scrypt item the at-rest
    /// pins are about.
    @MainActor
    private func freshService(persistEnclaveWrap: Bool = true) -> FernletLockService {
        let refusingStore: ((Data, LockKeychainKey, String) -> OSStatus)? = persistEnclaveWrap ? nil : { data, key, service in
            guard key != .seWrappedContentKey else { return errSecSuccess }
            return KeychainItem.store(data, for: key, service: service)
        }
        let service = FernletLockService(
            keychainService: "com.fernlet.lock.test.\(UUID().uuidString)",
            // reset() sweeps the sealed-content device keys too; keep that off the real service.
            sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
            // reset() also purges the pending-narrative buffer; keep that off the process-wide scope.
            narrativeBufferScope: uniqueNarrativeBufferScope(),
            keychainStore: refusingStore
        )
        try? service.reset()
        return service
    }

    /// Calls the PRODUCTION column-key derivation (`ColumnCrypto.deriveColumnKey`, via
    /// `@testable import FernletCrypto`) and returns the derived key's raw bytes —
    /// extracted with `withUnsafeBytes` rather than relying on `SymmetricKey` equality.
    private func derivedColumnKeyData(contentKey: Data, info: String, outputByteCount: Int) -> Data {
        ColumnCrypto.deriveColumnKey(
            contentKey: SymmetricKey(data: contentKey),
            info: info,
            outputByteCount: outputByteCount
        ).withUnsafeBytes { Data($0) }
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        #expect(status == errSecSuccess)
        return Data(bytes)
    }

    private func verifier(passcode: String, salt: Data) async throws -> Data {
        try await VerifierCache.shared.verifier(passcode: passcode, salt: salt)
    }

    private func hammingDistance(_ lhs: Data, _ rhs: Data) -> Int {
        zip(lhs, rhs).reduce(0) { partial, pair in
            partial + Int((pair.0 ^ pair.1).nonzeroBitCount)
        }
    }

    private func lockServiceSourceURL() -> URL {
        RepoRoot.url
            .appendingPathComponent("FernletKit/Sources/FernletLock/FernletLockService.swift")
    }

    private func loadKeychainData(account: String, service: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private actor VerifierCache {
    static let shared = VerifierCache()

    private var values: [String: Data] = [:]

    func verifier(passcode: String, salt: Data) async throws -> Data {
        let key = "\(Data(passcode.utf8).hexString)|\(salt.hexString)"
        if let value = values[key] { return value }
        let value = try await FernletLockCrypto.deriveVerifier(passcode: passcode, salt: salt)
        values[key] = value
        return value
    }
}
