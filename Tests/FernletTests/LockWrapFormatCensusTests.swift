// LockWrapFormatCensusTests.swift
// Fernlet
//
// Planted-fixture coverage for `LockWrapFormatCensus` — Phase 0 of
// Docs/Plan-Crypto-Standardization-2026-08-27.md. Every test plants byte-exact fixtures into an
// isolated keychain service of its own and deletes that service afterwards; the census under test
// is read-only, so the only writes in this file are the fixtures and the only deletes are cleanup.
//
// The legacy fixture here is the FIRST one in the tree: before this file nothing anywhere planted
// an unprefixed lock wrap, so the legacy branch of `FernletLockCrypto.unwrapContentKey` — and the
// count the whole migration plan is gated on — had never been exercised against real bytes.

import Foundation
import CryptoKit
import Security
import Testing
import FernletFoundation
@testable import FernletLock

@Suite(.serialized)
struct LockWrapFormatCensusTests {

    // MARK: - The two real formats

    /// A byte-exact LEGACY wrap — `ChaChaPoly.seal(contentKey, using: wrappingKey).combined`, no
    /// marker and no additional authenticated data — is counted as one legacy wrap.
    ///
    /// Phase 3 deleted the branch that used to open this shape, which makes the count matter MORE,
    /// not less: a row here is now a wrap `FernletLockCrypto.unwrapContentKey` refuses as
    /// ``FernletLockError/contentKeyWrapFormatRetired``, and this census is the only thing that can
    /// say how many of them a device holds.
    @Test func plantedLegacyWrapIsCountedAsOneLegacyWrap() throws {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.legacyWrapBytes()
        #expect(!legacy.starts(with: Data("FLW2".utf8)), "the legacy fixture must not accidentally carry the marker")
        #expect(Self.plant(legacy, service: service) == errSecSuccess)

        let report = LockWrapFormatCensus.inspect(service: service)
        #expect(report.state == .legacyUnprefixed)
        #expect(report.legacyWrapCount == 1)
        #expect(report.isIndeterminate == false)
        #expect(report.account == LockKeychainKey.wrappedContentKey.rawValue)
        #expect(report.account == "com.fernlet.lock.wrappedContentKey")
        #expect(report.keychainService == service)
    }

    /// A wrap produced by the PRODUCTION writer (`FernletLockCrypto.wrapContentKey`, the one every
    /// `configure()` and `changeCredential` goes through) is counted as V2 and as zero legacy wraps.
    /// Going through the real writer is what keeps this test honest: a hand-built fixture could
    /// agree with a census that had drifted from the shipping format.
    @Test func productionWriterOutputIsCountedAsV2() throws {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        let wrapped = try FernletLockCrypto.wrapContentKey(Self.contentKey, using: Self.wrappingKeyData)
        // The marker bytes are spelled out ONCE, here, so the census cannot silently agree with a
        // writer that changed its stamp (cf. FernletLockService.wrapContentKey).
        #expect(wrapped.starts(with: Data("FLW2".utf8)))
        #expect(Self.plant(wrapped, service: service) == errSecSuccess)

        let report = LockWrapFormatCensus.inspect(service: service)
        #expect(report.state == .v2Marked)
        #expect(report.legacyWrapCount == 0)
        #expect(report.isIndeterminate == false)
    }

    // MARK: - Absence, siblings, near misses

    /// An absent row reports `.absent` — never `.unreadable` — counts zero, and the census leaves
    /// the slot as empty as it found it.
    @Test func absentRowIsAbsentAndTheCensusCreatesNothing() {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }

        let report = LockWrapFormatCensus.inspect(service: service)
        #expect(report.state == .absent)
        #expect(report.state != .unreadable(errSecItemNotFound), "an absence must never be reported as a read failure")
        #expect(report.legacyWrapCount == 0)

        // Read-only proof for the absent path: no row was minted by the act of looking.
        #expect(KeychainItem.load(account: LockWrapFormatCensus.account, service: service) == nil)
        #expect(KeychainItem.loadAll(service: service).isEmpty)
    }

    /// The three sibling rows that hold key material under OTHER schemes — the Secure-Enclave ECIES
    /// wrap, the raw biometric bypass copy, and the custodian recovery blob — are not censused. With
    /// all three planted and the census target absent, the answer is still `.absent`: the census
    /// reads exactly one account, so an enclave wrap (which carries no marker at all) can never be
    /// miscounted as a legacy wrap.
    @Test func siblingKeyMaterialRowsAreNeverCensused() {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        for key in [LockKeychainKey.seWrappedContentKey, .biometricBypass, .recoveryBlob] {
            #expect(Self.plant(Self.siblingBytes, service: service, account: key.rawValue) == errSecSuccess)
        }

        let report = LockWrapFormatCensus.inspect(service: service)
        #expect(report.state == .absent, "a sibling row must not answer the wrapped-content-key question")
        #expect(report.legacyWrapCount == 0)
        #expect(KeychainItem.loadAll(service: service).count == 3, "the planted siblings must still be there")
    }

    /// Near misses count as LEGACY, not V2: a prefix has to be the whole four bytes. Anything else
    /// would let a corrupted or foreign row be waved through as already standardized.
    @Test func nearMissMarkersCountAsLegacy() throws {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.legacyWrapBytes()
        let nearMisses = [
            Data("FLW1".utf8) + legacy,        // right family, wrong version byte
            Data("FLW".utf8) + legacy,         // three of the four marker bytes
            Data("flw2".utf8) + legacy,        // right letters, wrong case
            Data([0x00]) + Data("FLW2".utf8) + legacy   // the marker, but not at offset 0
        ]
        for candidate in nearMisses {
            #expect(Self.plant(candidate, service: service) == errSecSuccess)
            let report = LockWrapFormatCensus.inspect(service: service)
            #expect(report.state == .legacyUnprefixed, "near miss classified as \(report.state)")
            #expect(report.legacyWrapCount == 1)
        }
    }

    // MARK: - The degenerate and the indeterminate

    /// An EMPTY row is its own bucket — neither a valid V2 wrap nor a plausible legacy box.
    /// Reporting it as legacy would queue a migration no re-wrap can complete; reporting it as V2
    /// would call a corrupt lock standardized. It counts as `nil`, so Phase 3 cannot read a broken
    /// slot as a clean zero.
    ///
    /// It is planted through the injected loader rather than the keychain because the house seam
    /// refuses to create it: `KeychainItem.store` rejects an empty payload with `errSecParam` (R5),
    /// which this test also pins — the empty row is only reachable from outside that seam.
    @Test func emptyRowIsMalformedRatherThanLegacyOrV2() {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        #expect(Self.plant(Data(), service: service) == errSecParam, "no first-party writer can file an empty row")

        #expect(LockWrapFormatCensus.classify(.found(Data())) == .malformedEmpty)
        let report = LockWrapFormatCensus.inspect(service: service, loadingRow: { _, _ in .found(Data()) })
        #expect(report.state == .malformedEmpty)
        #expect(report.legacyWrapCount == nil)
        #expect(report.isIndeterminate)
    }

    /// The row is `WhenUnlockedThisDeviceOnly`, so a locked device answers `errSecInteractionNotAllowed`.
    /// That must surface as `.unreadable` and count `nil` — collapsing it into `.absent` would let
    /// the census report "no legacy wrap" over a legacy wrap that is merely out of reach, and Phase 3
    /// deletes the legacy reader on the strength of that report.
    ///
    /// Injected rather than provoked: a simulator keychain cannot be put into that state.
    @Test func lockedDeviceReadIsUnreadableNeverAbsent() {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        let report = LockWrapFormatCensus.inspect(
            service: service,
            loadingRow: { _, _ in .unreadable(errSecInteractionNotAllowed) }
        )
        #expect(report.state == .unreadable(errSecInteractionNotAllowed))
        #expect(report.state != .absent, "a device-locked read is not an absence")
        #expect(report.legacyWrapCount == nil)
        #expect(report.isIndeterminate)
        #expect(KeychainItem.loadAll(service: service).isEmpty, "an unreadable census must not have written anything")
    }

    /// The pure classifier's whole mapping, keychain-free: found bytes by prefix, absent as absent,
    /// and any failing status carried through verbatim rather than normalized.
    @Test func classifierMapsEveryReadResultCase() throws {
        let legacy = try Self.legacyWrapBytes()
        let v2 = try FernletLockCrypto.wrapContentKey(Self.contentKey, using: Self.wrappingKeyData)
        #expect(LockWrapFormatCensus.classify(.found(v2)) == .v2Marked)
        #expect(LockWrapFormatCensus.classify(.found(legacy)) == .legacyUnprefixed)
        #expect(LockWrapFormatCensus.classify(.found(Data())) == .malformedEmpty)
        #expect(LockWrapFormatCensus.classify(.absent) == .absent)
        #expect(LockWrapFormatCensus.classify(.unreadable(errSecNotAvailable)) == .unreadable(errSecNotAvailable))
        #expect(LockWrapFormatCensus.classify(.unreadable(errSecAuthFailed)) == .unreadable(errSecAuthFailed))
    }

    /// An unnamed slot is indeterminate, not empty: a bad argument may never read as proof that no
    /// legacy wrap exists.
    @Test func unnamedServiceIsIndeterminate() {
        let report = LockWrapFormatCensus.inspect(service: "")
        #expect(report.state == .unreadable(errSecParam))
        #expect(report.legacyWrapCount == nil)
    }

    // MARK: - Read-only

    /// The census is read-only: the planted row is byte-identical after repeated calls, its account
    /// is still the only one in the slot, and nothing new appeared beside it.
    @Test func censusNeverMutatesTheRowItReads() throws {
        let service = Self.censusService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.legacyWrapBytes()
        #expect(Self.plant(legacy, service: service) == errSecSuccess)
        let before = try #require(KeychainItem.load(account: LockWrapFormatCensus.account, service: service))

        #expect(LockWrapFormatCensus.inspect(service: service).state == .legacyUnprefixed)
        #expect(LockWrapFormatCensus.inspect(service: service).state == .legacyUnprefixed)

        let after = try #require(KeychainItem.load(account: LockWrapFormatCensus.account, service: service))
        #expect(after == before, "the census rewrote the row it was only supposed to read")
        #expect(after == legacy, "the census must not have re-wrapped or re-encoded the planted bytes")
        let rows = KeychainItem.loadAll(service: service)
        #expect(rows.count == 1)
        #expect(rows.first?.account == LockWrapFormatCensus.account)
    }

    // MARK: - Fixtures

    /// A keychain slot no other suite can collide with; every test deletes its own in a `defer`.
    private static func censusService() -> String {
        "com.fernlet.lock.test.census.\(UUID().uuidString)"
    }

    /// Deterministic 32-byte stand-ins for the wrapping key and the content key. Neither is a real
    /// secret: no scrypt derivation, no passcode, and no unwrap happens anywhere in this file.
    private static let wrappingKeyData = Data(repeating: 0x5A, count: FernletLockCrypto.keyLength)
    private static let contentKey = Data(repeating: 0x11, count: FernletLockCrypto.keyLength)
    /// Filler for the sibling rows — their formats are irrelevant precisely because the census
    /// never looks at them.
    private static let siblingBytes = Data(repeating: 0xC3, count: 48)

    /// The pre-`FLW2` wrap, byte for byte: a bare ChaChaPoly combined box (nonce ‖ ciphertext ‖ tag)
    /// over the content key, sealed with no additional authenticated data — the exact shape
    /// `FernletLockCrypto.unwrapContentKey` now refuses by name.
    private static func legacyWrapBytes() throws -> Data {
        try ChaChaPoly.seal(contentKey, using: SymmetricKey(data: wrappingKeyData)).combined
    }

    /// Files `bytes` at `account` under `service` with the production accessibility class, and hands
    /// back the status so the caller pins it (`KeychainItem.store` is not `@discardableResult`).
    private static func plant(
        _ bytes: Data,
        service: String,
        account: String = LockWrapFormatCensus.account
    ) -> OSStatus {
        KeychainItem.store(
            bytes,
            account: account,
            service: service,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }
}
