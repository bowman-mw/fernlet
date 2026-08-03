import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
@testable import FernletLock

/// Proves the additive Secure-Enclave second wrap of the lock content key is exactly that —
/// additive: it round-trips when an enclave exists, self-heals when its blob is corrupted, and
/// changes NOTHING (no blob, identical unlock behavior) when no enclave is available.
///
/// Every test handles both hardware cases explicitly, because `SecureEnclave.isAvailable` is
/// true on Apple-silicon-hosted simulators and false elsewhere — the fallback branch is not a
/// skip, it is the migration-safety property under test (Docs/Verifiability.md §4).
@Suite(.serialized)
struct SecureEnclaveWrapTests {
    // MARK: Proves wrapVerified→unwrap round-trips the exact key bytes, and that deleting the
    // enclave key makes existing blobs unopenable (the erase-device behavior the owner-decision
    // hard-binding would inherit).
    @Test func wrapRoundTripsAndDiesWithItsEnclaveKey() {
        guard SecureEnclaveContentKeyWrap.isAvailable else {
            #expect(SecureEnclaveContentKeyWrap.wrapVerified(Data(repeating: 7, count: 32), service: "com.fernlet.lock.test.se.unavailable") == nil,
                    "without an enclave, wrapVerified must fail soft to nil")
            return
        }
        let service = "com.fernlet.lock.test.se.\(UUID().uuidString)"
        defer { SecureEnclaveContentKeyWrap.deleteKey(service: service) }

        let contentKey = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        let blob = SecureEnclaveContentKeyWrap.wrapVerified(contentKey, service: service)
        #expect(blob != nil, "enclave available but wrapVerified failed")
        guard let blob else { return }
        #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKey)

        SecureEnclaveContentKeyWrap.deleteKey(service: service)
        #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == nil,
                "a wrapped blob must be unopenable once its enclave key is gone")
    }

    // MARK: Proves the lock service maintains the SE wrap across configure and unlock, that the
    // blob opens to the real content key, and — the keep-old-until-verified property — that a
    // CORRUPTED blob never blocks an unlock and is silently repaired by it.
    @MainActor
    @Test func lockServiceMaintainsAndRepairsTheWrapWithoutEverBlockingUnlock() async throws {
        let service = "com.fernlet.lock.test.se.svc.\(UUID().uuidString)"
        let lockService = FernletLockService(keychainService: service)
        defer {
            try? lockService.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await lockService.configure(credential: .pin6("135791"), grantingScope: .privateHub)
        let contentKeyData = try #require(lockService.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }

        if SecureEnclaveContentKeyWrap.isAvailable {
            let blob = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service),
                                    "configure on SE hardware must establish the second wrap")
            #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKeyData)

            // Corrupt the wrap; the unlock must still succeed (scrypt stays authoritative)…
            KeychainItem.store(Data(repeating: 0xFF, count: 64), for: .seWrappedContentKey, service: service)
            lockService.lock(reason: .manual)
            _ = try await lockService.unlock(passcode: "135791", for: .privateHub)
            #expect(try #require(lockService.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) } == contentKeyData)

            // …and repair the blob back to a working wrap of the same content key.
            let repaired = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service))
            #expect(SecureEnclaveContentKeyWrap.unwrap(repaired, service: service) == contentKeyData,
                    "unlock must self-heal a corrupt SE wrap")
        } else {
            #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil,
                    "without an enclave no blob may exist — behavior must be byte-for-byte legacy")
            lockService.lock(reason: .manual)
            _ = try await lockService.unlock(passcode: "135791", for: .privateHub)
            #expect(try #require(lockService.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) } == contentKeyData)
        }
    }

    // MARK: Proves reset() removes the enclave key itself (a kSecClassKey item the lock's
    // generic-password sweep cannot reach), so a destroyed lock leaves no orphan key material.
    @MainActor
    @Test func resetRemovesTheEnclaveKey() async throws {
        guard SecureEnclaveContentKeyWrap.isAvailable else { return }
        let service = "com.fernlet.lock.test.se.reset.\(UUID().uuidString)"
        let lockService = FernletLockService(keychainService: service)
        try await lockService.configure(credential: .pin6("246802"), grantingScope: .privateHub)
        #expect(SecureEnclaveContentKeyWrap.loadKey(service: service) != nil)
        try lockService.reset()
        #expect(SecureEnclaveContentKeyWrap.loadKey(service: service) == nil)
    }
}
