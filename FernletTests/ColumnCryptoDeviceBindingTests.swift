import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto

/// Pins the device-bound sealed-column format (`ColumnCrypto` v2 + `DeviceBindingID`) and — the
/// migration-safety half — proves that every pre-binding (legacy) blob still opens unchanged.
///
/// The binding overrides use `DeviceBindingID`'s `@TaskLocal` test seam, so each test pins its
/// own install identity without touching the real keychain row or leaking into concurrently
/// running repository tests (which seal against the real row).
struct ColumnCryptoDeviceBindingTests {
    /// A fixed 32-byte content key shared by the tests (the binding, not the key, is under test).
    private let contentKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    /// Install identity "A" — the device that seals.
    private let installA = Data(repeating: 0xA1, count: 16)
    /// Install identity "B" — a different device/install attempting to open A's ciphertext.
    private let installB = Data(repeating: 0xB2, count: 16)

    /// Seals `value` while the binding override is pinned to `override`.
    private func seal(_ value: String, label: String, override: DeviceBindingID.TestOverride) throws -> Data {
        try DeviceBindingID.$testOverride.withValue(override) {
            try ColumnCrypto(label: label).sealString(value, contentKey: contentKey)
        }
    }

    /// Opens `blob` while the binding override is pinned to `override`.
    private func open(_ blob: Data, label: String, override: DeviceBindingID.TestOverride) throws -> String? {
        try DeviceBindingID.$testOverride.withValue(override) {
            try ColumnCrypto(label: label).openString(blob, contentKey: contentKey)
        }
    }

    // MARK: Proves a device-bound seal round-trips and carries the v2 version tag.
    @Test func deviceBoundSealRoundTripsAndIsVersionTagged() throws {
        let sealed = try seal("a private thought", label: "journal-narrative", override: .identifier(installA))
        #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersion)
        let opened = try open(sealed, label: "journal-narrative", override: .identifier(installA))
        #expect(opened == "a private thought")
    }

    // MARK: MIGRATION SAFETY: proves a legacy (pre-binding, no-AAD, unprefixed) blob still opens
    // on an install that now has a binding ID — the dual-open fallback existing users depend on.
    @Test func legacyBlobStillOpensOnABoundInstall() throws {
        let legacySealed = try seal("written before binding existed", label: "worry-box", override: .unavailable)
        // Legacy layout sanity: exactly nonce(12) + ciphertext + tag(16), i.e. no version prefix.
        #expect(legacySealed.count == 12 + "written before binding existed".utf8.count + 16)
        let opened = try open(legacySealed, label: "worry-box", override: .identifier(installA))
        #expect(opened == "written before binding existed")
    }

    // MARK: Proves the binding property itself: a v2 blob sealed on install A does NOT open on
    // install B even with the correct content key — the ciphertext, not just the key, is bound.
    @Test func deviceBoundBlobRefusesToOpenOnAnotherInstall() throws {
        let sealed = try seal("bound to install A", label: "intimacy-log", override: .identifier(installA))
        #expect(throws: (any Error).self) {
            _ = try self.open(sealed, label: "intimacy-log", override: .identifier(self.installB))
        }
        // And on an install with no binding at all (fresh keychain), it must also refuse.
        #expect(throws: (any Error).self) {
            _ = try self.open(sealed, label: "intimacy-log", override: .unavailable)
        }
    }

    // MARK: Proves the 1-in-256 ambiguity is handled: a LEGACY blob whose first (nonce) byte
    // happens to equal the v2 version tag still opens via the fallback path.
    @Test func legacyBlobStartingWithTheVersionByteStillOpens() throws {
        var collidingBlob: Data?
        for _ in 0..<8192 {  // P(miss all) ≈ (255/256)^8192 ≈ 10^-14
            let sealed = try seal("nonce collision", label: "menstrual-narrative", override: .unavailable)
            if sealed.first == ColumnCrypto.deviceBoundFormatVersion {
                collidingBlob = sealed
                break
            }
        }
        let blob = try #require(collidingBlob, "could not produce a legacy blob starting with the version byte")
        let opened = try open(blob, label: "menstrual-narrative", override: .identifier(installA))
        #expect(opened == "nonce collision")
    }

    // MARK: MIGRATION ROUND TRIP: models the routine re-seal (edit / lock-setup migration /
    // restore-on-unhide) that progressively rebinds the legacy corpus — open legacy, re-seal,
    // and the result is v2 and opens only on this install.
    @Test func routineReSealRebindsALegacyBlob() throws {
        let legacySealed = try seal("migrate me", label: "journal-narrative", override: .unavailable)
        let plaintext = try #require(try open(legacySealed, label: "journal-narrative", override: .identifier(installA)))
        let rebound = try seal(plaintext, label: "journal-narrative", override: .identifier(installA))
        #expect(rebound.first == ColumnCrypto.deviceBoundFormatVersion)
        let reopened = try open(rebound, label: "journal-narrative", override: .identifier(installA))
        #expect(reopened == "migrate me")
        #expect(throws: (any Error).self) {
            _ = try self.open(rebound, label: "journal-narrative", override: .identifier(self.installB))
        }
    }

    // MARK: Proves the Codable seal/open pair speaks the same two-generation format as the
    // string pair (both route through the shared core).
    @Test func codableSealsAreDeviceBoundAndLegacyCompatible() throws {
        let crypto = ColumnCrypto(label: "menstrual-narrative")
        let value = ["cramps", "fatigue"]

        let sealed = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.seal(value, contentKey: contentKey)
        }
        #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersion)
        let opened: [String]? = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.open(sealed, contentKey: contentKey)
        }
        #expect(opened == value)

        let legacy = try DeviceBindingID.$testOverride.withValue(.unavailable) {
            try crypto.seal(value, contentKey: contentKey)
        }
        let legacyOpened: [String]? = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.open(legacy, contentKey: contentKey)
        }
        #expect(legacyOpened == value)
    }

    // MARK: FAIL-OPEN: proves that when no durable binding ID exists, sealing degrades to the
    // legacy format (and still round-trips) rather than blocking or half-binding a save.
    @Test func unavailableBindingSealsLegacyAndRoundTrips() throws {
        let sealed = try seal("no binding available", label: "worry-box", override: .unavailable)
        // Legacy combined layout: 12-byte nonce + ciphertext + 16-byte tag, no prefix.
        #expect(sealed.count == 12 + "no binding available".utf8.count + 16)
        let opened = try open(sealed, label: "worry-box", override: .unavailable)
        #expect(opened == "no binding available")
    }

    // MARK: Proves the production install ID is durable and stable across calls (the real
    // keychain row, exercised without overrides), and correctly sized.
    @Test func realInstallBindingIDIsStableAndSixteenBytes() {
        guard let first = DeviceBindingID.current() else {
            Issue.record("DeviceBindingID.current() returned nil on the test keychain — minting failed")
            return
        }
        #expect(first.count == 16)
        #expect(DeviceBindingID.current() == first)
    }
}
