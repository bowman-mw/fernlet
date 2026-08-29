import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto

/// Pins the device-bound sealed-column format (`ColumnCrypto` v2/v3 + `DeviceBindingID`) and — the
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

    /// Produces a genuine v2 blob byte-for-byte the way the pre-purpose-separation sealer did:
    /// the v2 version tag, then `combined`, sealed under the column key with the install binding
    /// ALONE as additional authenticated data — where v3 authenticates the column purpose *and*
    /// the binding. Nothing else in the suite can make one, because `sealString` has written v3
    /// exclusively since the format split, so the v2 open path would otherwise go unexercised.
    ///
    /// The HKDF is spelled out here instead of calling `ColumnCrypto.deriveColumnKey`: a
    /// compatibility fixture must not move when the production derivation moves. Pinned this way,
    /// a change to the column-key derivation fails these tests — which is the alarm we want, since
    /// it would equally stop the real v2 rows on disk from opening.
    private func sealV2(_ value: String, label: String, binding: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: contentKey,
            info: Data(label.utf8),
            outputByteCount: 32
        )
        let combined = try ChaChaPoly.seal(Data(value.utf8), using: key, authenticating: binding).combined
        return Data([ColumnCrypto.deviceBoundFormatVersionV2]) + combined
    }

    /// Produces a genuine LEGACY blob — bare `combined`, no version prefix, no AAD — the way the
    /// pre-binding sealer wrote every row.
    ///
    /// Hand-built for the same reason ``sealV2(_:label:binding:)`` is, and now for a second reason:
    /// **production can no longer make one.** Through Phase 2.6 these fixtures were minted by
    /// sealing with the binding override pinned to `.unavailable`, riding `sealPlaintext`'s
    /// fail-open; Phase 3 closed that branch (owner decision D4), so the migration-safety tests
    /// below would otherwise have lost their corpus along with the writer. The legacy READ path is
    /// untouched and still has to be exercised — real rows written by shipped builds are out there.
    private func sealLegacy(_ plaintext: Data, label: String) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: contentKey,
            info: Data(label.utf8),
            outputByteCount: 32
        )
        return try ChaChaPoly.seal(plaintext, using: key).combined
    }

    /// ``sealLegacy(_:label:)`` over a UTF-8 string, the shape most callers here want.
    private func sealLegacy(_ value: String, label: String) throws -> Data {
        try sealLegacy(Data(value.utf8), label: label)
    }

    // MARK: Proves a device-bound seal round-trips and carries the current version tag.
    @Test func deviceBoundSealRoundTripsAndIsVersionTagged() throws {
        let sealed = try seal("a private thought", label: "journal-narrative", override: .identifier(installA))
        #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersionV3)
        let opened = try open(sealed, label: "journal-narrative", override: .identifier(installA))
        #expect(opened == "a private thought")
    }

    // MARK: MIGRATION SAFETY: proves a legacy (pre-binding, no-AAD, unprefixed) blob still opens
    // on an install that now has a binding ID — the dual-open fallback existing users depend on.
    @Test func legacyBlobStillOpensOnABoundInstall() throws {
        let legacySealed = try sealLegacy("written before binding existed", label: "worry-box")
        // Legacy layout sanity: exactly nonce(12) + ciphertext + tag(16), i.e. no version prefix.
        #expect(legacySealed.count == 12 + "written before binding existed".utf8.count + 16)
        let opened = try open(legacySealed, label: "worry-box", override: .identifier(installA))
        #expect(opened == "written before binding existed")
    }

    // MARK: Proves the binding property itself: a device-bound blob sealed on install A does NOT open on
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

    // MARK: Proves the 2-in-256 ambiguity is handled: a LEGACY blob whose first (nonce) byte
    // happens to equal a recognized version tag still opens via the fallback path.
    @Test func legacyBlobStartingWithTheVersionByteStillOpens() throws {
        var collidingBlob: Data?
        for _ in 0..<8192 {  // P(miss all) ≈ (254/256)^8192 ≈ 10^-28
            let sealed = try sealLegacy("nonce collision", label: "menstrual-narrative")
            if sealed.first == ColumnCrypto.deviceBoundFormatVersionV2
                || sealed.first == ColumnCrypto.deviceBoundFormatVersionV3 {
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
    // and the result is current-version and opens only on this install.
    @Test func routineReSealRebindsALegacyBlob() throws {
        let legacySealed = try sealLegacy("migrate me", label: "journal-narrative")
        let plaintext = try #require(try open(legacySealed, label: "journal-narrative", override: .identifier(installA)))
        let rebound = try seal(plaintext, label: "journal-narrative", override: .identifier(installA))
        #expect(rebound.first == ColumnCrypto.deviceBoundFormatVersionV3)
        let reopened = try open(rebound, label: "journal-narrative", override: .identifier(installA))
        #expect(reopened == "migrate me")
        #expect(throws: (any Error).self) {
            _ = try self.open(rebound, label: "journal-narrative", override: .identifier(self.installB))
        }
    }

    // MARK: V2 COMPATIBILITY: proves a genuine v2 blob — the pre-purpose generation, binding-only
    // AAD — still opens on the install that sealed it. Fresh seals are v3, so without the
    // hand-built fixture the v2 arm of the open path is dead code no test reaches.
    @Test func v2BlobOpensOnTheSealingInstall() throws {
        let value = "sealed before purposes existed"
        let v2Sealed = try sealV2(value, label: "journal-narrative", binding: installA)
        // v2 layout: version byte + nonce(12) + ciphertext + tag(16) — one byte longer than legacy.
        #expect(v2Sealed.first == ColumnCrypto.deviceBoundFormatVersionV2)
        #expect(v2Sealed.count == 1 + 12 + value.utf8.count + 16)
        #expect(try open(v2Sealed, label: "journal-narrative", override: .identifier(installA)) == value)
    }

    // MARK: Proves the v2 binding property survived the format split: a v2 blob sealed on install A
    // still refuses to open on install B, and on an install with no binding row at all — the
    // legacy fallback must not quietly rescue a blob whose AAD cannot be reproduced.
    @Test func v2BlobRefusesToOpenOnAnotherInstall() throws {
        let v2Sealed = try sealV2("bound to install A", label: "intimacy-log", binding: installA)
        #expect(throws: (any Error).self) {
            _ = try self.open(v2Sealed, label: "intimacy-log", override: .identifier(self.installB))
        }
        #expect(throws: (any Error).self) {
            _ = try self.open(v2Sealed, label: "intimacy-log", override: .unavailable)
        }
    }

    // MARK: V2 → V3 MIGRATION: the same routine re-seal that rebinds legacy rows also upgrades a v2
    // row to v3 (purpose + binding AAD) — the path that progressively drains the v2 generation —
    // and the upgraded row stays bound to this install.
    @Test func routineReSealMigratesAV2BlobToV3() throws {
        let v2Sealed = try sealV2("migrate me to v3", label: "worry-box", binding: installA)
        let plaintext = try #require(try open(v2Sealed, label: "worry-box", override: .identifier(installA)))
        let migrated = try seal(plaintext, label: "worry-box", override: .identifier(installA))
        #expect(migrated.first == ColumnCrypto.deviceBoundFormatVersionV3)
        #expect(try open(migrated, label: "worry-box", override: .identifier(installA)) == "migrate me to v3")
        #expect(throws: (any Error).self) {
            _ = try self.open(migrated, label: "worry-box", override: .identifier(self.installB))
        }
    }

    // MARK: RESILIENCE, v2 arm: the v2 open path keeps its own binding-read-error branch, so a
    // transient keychain outage over a v2 row must also surface as the retryable ReadError rather
    // than an authentication failure that reads like corruption — and the row must open unchanged
    // once the keychain recovers.
    @Test func v2BlobSurfacesATransientBindingReadErrorAsRetryable() throws {
        let v2Sealed = try sealV2("retry my v2 row", label: "menstrual-narrative", binding: installA)
        #expect(throws: DeviceBindingID.ReadError.self) {
            _ = try self.open(v2Sealed, label: "menstrual-narrative", override: .readError)
        }
        let opened = try open(v2Sealed, label: "menstrual-narrative", override: .identifier(installA))
        #expect(opened == "retry my v2 row")
    }

    // MARK: Proves the Codable seal/open pair speaks the same two-generation format as the
    // string pair (both route through the shared core).
    @Test func codableSealsAreDeviceBoundAndLegacyCompatible() throws {
        let crypto = ColumnCrypto(label: "menstrual-narrative")
        let value = ["cramps", "fatigue"]

        let sealed = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.seal(value, contentKey: contentKey)
        }
        #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersionV3)
        let opened: [String]? = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.open(sealed, contentKey: contentKey)
        }
        #expect(opened == value)

        let legacy = try sealLegacy(try JSONEncoder().encode(value), label: "menstrual-narrative")
        let legacyOpened: [String]? = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.open(legacy, contentKey: contentKey)
        }
        #expect(legacyOpened == value)
    }

    // MARK: FAIL-CLOSE: proves that when no durable binding ID exists, sealing REFUSES — it
    // throws rather than degrading to the un-domained legacy format. This is the inversion of the
    // old `unavailableBindingSealsLegacyAndRoundTrips` pin, and it is the whole point of Phase 3's
    // write-side closure (owner decision D4): `DeviceBindingID.current()` answers nil on any
    // keychain read/add failure and its row is `…AfterFirstUnlockThisDeviceOnly`, so while the
    // fail-open lived, the pre-first-unlock window alone could mint a fresh legacy blob and no
    // format-census zero could ever be a latch. A save now fails loudly instead.
    @Test func unavailableBindingRefusesToSeal() throws {
        let crypto = ColumnCrypto(label: "worry-box")
        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.sealString("no binding available", contentKey: self.contentKey)
            }
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.sealOptionalString("no binding available", contentKey: self.contentKey)
            }
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.seal(["cramps", "fatigue"], contentKey: self.contentKey)
            }
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.sealPlaintextV3Strict(Data("no binding available".utf8), contentKey: self.contentKey)
            }
        }
    }

    // MARK: RESILIENCE: a transient keychain READ ERROR (row state unknown, nothing cached)
    // must surface as the distinct, retryable DeviceBindingID.ReadError — not as an
    // authentication failure that reads like corrupted data — and the same blob must open
    // unchanged once the keychain recovers.
    @Test func transientBindingReadErrorIsRetryableAndSelfHeals() throws {
        let sealed = try seal("retry me", label: "journal-narrative", override: .identifier(installA))
        #expect(throws: DeviceBindingID.ReadError.self) {
            _ = try self.open(sealed, label: "journal-narrative", override: .readError)
        }
        let opened = try open(sealed, label: "journal-narrative", override: .identifier(installA))
        #expect(opened == "retry me")
    }

    // MARK: RESILIENCE: during the same read error, legacy blobs — including the 2-in-256 blob
    // whose first nonce byte collides with a version tag — keep opening; the outage affects
    // only blobs that genuinely need the binding.
    @Test func legacyBlobsStillOpenDuringABindingReadError() throws {
        let legacy = try sealLegacy("still readable", label: "worry-box")
        #expect(try open(legacy, label: "worry-box", override: .readError) == "still readable")

        var collidingBlob: Data?
        for _ in 0..<8192 {  // P(miss all) ≈ (254/256)^8192 ≈ 10^-28
            let sealed = try sealLegacy("collision", label: "worry-box")
            if sealed.first == ColumnCrypto.deviceBoundFormatVersionV2
                || sealed.first == ColumnCrypto.deviceBoundFormatVersionV3 {
                collidingBlob = sealed
                break
            }
        }
        let blob = try #require(collidingBlob, "could not produce a legacy blob starting with the version byte")
        #expect(try open(blob, label: "worry-box", override: .readError) == "collision")
    }

    // MARK: FAIL-CLOSE parity: a transient keychain READ ERROR during SEAL refuses exactly like
    // an authoritatively absent binding. Both reach the writer as `current() == nil`, and the
    // closure must not distinguish them — a save that degrades to legacy "only during an outage"
    // is still a save in the format the round exists to retire. (The read side keeps the
    // distinction: `ReadError` there means "try again", not "corrupted" — see
    // `transientBindingReadErrorIsRetryableAndSelfHeals`.)
    @Test func sealDuringABindingReadErrorAlsoRefuses() throws {
        let crypto = ColumnCrypto(label: "journal-narrative")
        DeviceBindingID.$testOverride.withValue(.readError) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.sealString("saved during outage", contentKey: self.contentKey)
            }
        }
    }

    // MARK: - Phase 2.6 pins: the rung-reporting refactor and the strict v3 seal

    // MARK: C1 — BEHAVIOR-PRESERVATION PROOF for the openBlob → openReportingRung refactor:
    // for every rung (v3 / v2 / legacy / both collided slivers) the receipt-bearing dispatch
    // returns the same plaintext the shipping string reader does, with the right rung receipt;
    // and for every failure shape (garbage, truncated, ReadError precedence) both paths throw
    // the same class of error. The migrator's tallies are only as honest as these receipts.
    @Test func openReportingRungMatchesOpenBlobOnEveryRung() throws {
        let crypto = ColumnCrypto(label: "journal-narrative")

        // v3 rung.
        let v3 = try seal("rung three", label: "journal-narrative", override: .identifier(installA))
        try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            let opened = try crypto.openReportingRung(v3, contentKey: contentKey)
            #expect(opened.rung == .v3)
            #expect(String(data: opened.plaintext, encoding: .utf8) == "rung three")
            #expect(try crypto.openString(v3, contentKey: contentKey) == "rung three")
        }

        // v2 rung (the hand-built pre-purpose generation).
        let v2 = try sealV2("rung two", label: "journal-narrative", binding: installA)
        try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            let opened = try crypto.openReportingRung(v2, contentKey: contentKey)
            #expect(opened.rung == .v2)
            #expect(String(data: opened.plaintext, encoding: .utf8) == "rung two")
        }

        // Legacy rung, unprefixed: the fallback, with a nil collision receipt.
        let legacy = try sealLegacy("rung legacy", label: "journal-narrative")
        try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            let opened = try crypto.openReportingRung(legacy, contentKey: contentKey)
            #expect(opened.rung == .legacy(markerCollision: nil))
            #expect(String(data: opened.plaintext, encoding: .utf8) == "rung legacy")
        }

        // Both collided slivers: a LEGACY blob whose first nonce byte is a marker opens via the
        // fallback and the receipt names the collided marker — legacy proven BY OPEN, the second
        // witness Phase 3 needs against the census's byte-only upper bounds.
        for marker in [ColumnCrypto.deviceBoundFormatVersionV3, ColumnCrypto.deviceBoundFormatVersionV2] {
            var collided: Data?
            for _ in 0..<8192 {  // P(miss all) ≈ (255/256)^8192 ≈ 1e-14
                let candidate = try sealLegacy("collide", label: "journal-narrative")
                if candidate.first == marker {
                    collided = candidate
                    break
                }
            }
            let blob = try #require(collided, "could not draw a colliding legacy blob")
            let expectedCollision: ColumnCryptoStoredFormat =
                marker == ColumnCrypto.deviceBoundFormatVersionV3 ? .v3Marked : .v2Marked
            try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
                let opened = try crypto.openReportingRung(blob, contentKey: contentKey)
                #expect(opened.rung == .legacy(markerCollision: expectedCollision))
                #expect(String(data: opened.plaintext, encoding: .utf8) == "collide")
            }
        }

        // Failure shapes: garbage and a truncated blob throw on BOTH paths.
        let garbage = Data((0..<44).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 13) })
        DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            #expect(throws: (any Error).self) { _ = try crypto.openReportingRung(garbage, contentKey: self.contentKey) }
            #expect(throws: (any Error).self) { _ = try crypto.openString(garbage, contentKey: self.contentKey) }
            let truncated = v3.prefix(8)
            #expect(throws: (any Error).self) { _ = try crypto.openReportingRung(Data(truncated), contentKey: self.contentKey) }
        }

        // ReadError precedence: a marked blob during a keychain outage surfaces the retryable
        // ReadError on the receipt path exactly as on the shipping path.
        DeviceBindingID.$testOverride.withValue(.readError) {
            #expect(throws: DeviceBindingID.ReadError.self) {
                _ = try crypto.openReportingRung(v3, contentKey: self.contentKey)
            }
            #expect(throws: DeviceBindingID.ReadError.self) {
                _ = try crypto.openString(v3, contentKey: self.contentKey)
            }
        }
    }

    // MARK: C2 — the strict seal REFUSES without a binding (both the authoritative absence and
    // the transient read error), and never emits a legacy blob. It was the format migrator's only
    // seal entry in Phase 2.6; since Phase 3 collapsed the fall-open twin into it, it is the whole
    // codebase's, and must be structurally unable to re-mint the format the pass exists to retire.
    @Test func sealPlaintextV3StrictRefusesWithoutBinding() throws {
        let crypto = ColumnCrypto(label: "worry-box")
        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.sealPlaintextV3Strict(Data("refuse me".utf8), contentKey: self.contentKey)
            }
        }
        DeviceBindingID.$testOverride.withValue(.readError) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                _ = try crypto.sealPlaintextV3Strict(Data("refuse me too".utf8), contentKey: self.contentKey)
            }
        }
    }

    // MARK: C3 — the strict seal's output is byte-compatible with the shipping writer's v3: it
    // starts with the version tag, opens under the v3 rung on the sealing install, and refuses
    // on any other install.
    @Test func strictSealOutputStartsWith0x03AndOpensV3() throws {
        let crypto = ColumnCrypto(label: "intimacy-log")
        let plaintext = Data("strictly bound".utf8)
        let sealed = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.sealPlaintextV3Strict(plaintext, contentKey: contentKey)
        }
        #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersionV3)
        try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            let opened = try crypto.openReportingRung(sealed, contentKey: contentKey)
            #expect(opened.rung == .v3)
            #expect(opened.plaintext == plaintext)
        }
        #expect(throws: (any Error).self) {
            try DeviceBindingID.$testOverride.withValue(.identifier(self.installB)) {
                _ = try crypto.openReportingRung(sealed, contentKey: self.contentKey)
            }
        }
    }

    // MARK: C4 — THE LINE IN THE SAND, now drawn on the other side. Through Phase 2.6 this pin
    // asserted that the shipping writer STILL fell open to the unprefixed legacy format, so an
    // accidental early close would fail loudly. Phase 3 closed it deliberately (owner decision
    // D4), so the pin is inverted: nothing in the tree may mint an un-domained blob.
    //
    // The proof is by LENGTH and by first byte together: every emitted blob is v3-tagged and one
    // byte longer than the legacy layout would be, over enough draws that a nonce collision
    // cannot manufacture a pass. And with the binding gone, no bytes come out at all.
    @Test func noWriterCanStillMintAnUnprefixedLegacyBlob() throws {
        let crypto = ColumnCrypto(label: "menstrual-narrative")
        let value = "fail-open survivor"
        // With a binding: always v3, never the legacy layout.
        try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            for _ in 0..<64 {
                let sealed = try crypto.sealString(value, contentKey: contentKey)
                #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersionV3)
                #expect(sealed.count == 1 + 12 + value.utf8.count + 16)
            }
        }
        // Without one: no blob at all, in either flavor of "no binding".
        for override in [DeviceBindingID.TestOverride.unavailable, .readError] {
            DeviceBindingID.$testOverride.withValue(override) {
                #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                    _ = try crypto.sealString(value, contentKey: self.contentKey)
                }
            }
        }
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
