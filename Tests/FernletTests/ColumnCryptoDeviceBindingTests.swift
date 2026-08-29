import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto

/// Pins the device-bound sealed-column format (`ColumnCrypto` V3 + `DeviceBindingID`) and — the
/// half that used to be "migration safety" — proves that every RETIRED generation is now refused
/// **by name**, never opened and never mistaken for corruption.
///
/// Phase 3 of the crypto standardization round left V3 as the only readable format. Every test
/// below that once asserted "a legacy/v2 blob still opens" is inverted here rather than deleted:
/// the fixtures that mint those bytes are kept precisely so the REFUSAL stays exercised, and an
/// inverted pin is what stops a future change quietly re-opening a format the round retired.
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
    /// exclusively since the format split — and since Phase 3 deleted the v2 rung, the only thing
    /// left to exercise is the REFUSAL, which still needs real v2 bytes to refuse.
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
    /// below would otherwise have lost their corpus along with the writer. Phase 3 then deleted the
    /// legacy READ path too, so what these bytes exercise now is the named refusal — which is the
    /// thing most worth pinning, because real rows written by shipped builds are out there and a
    /// refusal that cannot name them is indistinguishable from a corruption bug.
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

    // MARK: RETIRED FORMAT, unprefixed: a legacy (pre-binding, no-AAD) blob is REFUSED by name on
    // an install that has a binding. This pin is the inversion of `legacyBlobStillOpensOnABoundInstall`:
    // the dual-open fallback existing rows depended on is gone, and what matters now is that the
    // failure SAYS SO — `retiredFormat(.unprefixed)`, not a Poly1305 authentication error that would
    // read as "your data is corrupt" and send someone looking for a corruption bug that isn't there.
    @Test func legacyBlobIsRefusedByNameOnABoundInstall() throws {
        let legacySealed = try sealLegacy("written before binding existed", label: "worry-box")
        // Legacy layout sanity: exactly nonce(12) + ciphertext + tag(16), i.e. no version prefix.
        #expect(legacySealed.count == 12 + "written before binding existed".utf8.count + 16)
        #expect(throws: ColumnCrypto.SealedColumnOpenError.retiredFormat(.unprefixed)) {
            _ = try self.open(legacySealed, label: "worry-box", override: .identifier(self.installA))
        }
    }

    // MARK: Proves the binding property itself: a device-bound blob sealed on install A does NOT open on
    // install B even with the correct content key — the ciphertext, not just the key, is bound.
    @Test func deviceBoundBlobRefusesToOpenOnAnotherInstall() throws {
        let sealed = try seal("bound to install A", label: "intimacy-log", override: .identifier(installA))
        #expect(throws: (any Error).self) {
            _ = try self.open(sealed, label: "intimacy-log", override: .identifier(self.installB))
        }
        // On an install with no binding row at all the AAD cannot be rebuilt, and that is its own
        // named terminal state — distinct from an authentication failure, because nothing is wrong
        // with the ciphertext.
        #expect(throws: ColumnCrypto.SealedColumnOpenError.installBindingMissing) {
            _ = try self.open(sealed, label: "intimacy-log", override: .unavailable)
        }
    }

    // MARK: THE RESOLUTION THAT WAS LOST, pinned so it cannot be forgotten. A legacy blob whose
    // first (nonce) byte happens to equal a version tag is indistinguishable from a marked blob by
    // bytes alone — 2 in 256 of them. Until Phase 3 the unconditional fallback resolved that sliver
    // BY OPEN. Nothing can now: the `0x02` collision is reported as a retired v2 row (true enough —
    // it is retired either way), and the `0x03` collision is tried as V3 and fails AUTHENTICATION,
    // which is the one refusal in this file that cannot name what it found. That is a real loss and
    // this pin is where it is recorded.
    @Test func aCollidedLegacyBlobCanNoLongerBeResolvedByOpen() throws {
        let v2Collision = try drawLegacyBlob(startingWith: ColumnCrypto.deviceBoundFormatVersionV2)
        #expect(throws: ColumnCrypto.SealedColumnOpenError.retiredFormat(.v2Marked)) {
            _ = try self.open(v2Collision, label: "menstrual-narrative", override: .identifier(self.installA))
        }
        // The 0x03 collision: the marker says V3, so the reader believes it and the failure is an
        // AUTHENTICATION failure — deliberately asserted as "not a SealedColumnOpenError", because
        // the honest statement is that this one row cannot be named, not that it fails somehow.
        let v3Collision = try drawLegacyBlob(startingWith: ColumnCrypto.deviceBoundFormatVersionV3)
        do {
            _ = try open(v3Collision, label: "menstrual-narrative", override: .identifier(installA))
            Issue.record("a legacy blob must not open under the V3 rung")
        } catch let error as ColumnCrypto.SealedColumnOpenError {
            Issue.record("a 0x03-collided legacy blob classified as \(error) instead of failing authentication")
        } catch {
            // The expected shape: CryptoKit's own authentication error.
        }
    }

    // MARK: Draws a legacy blob whose first nonce byte equals `marker`. Bounded (R2) and
    // astronomically unlikely to miss: P(miss all 8192) ≈ (255/256)^8192 ≈ 1e-14.
    private func drawLegacyBlob(startingWith marker: UInt8) throws -> Data {
        var drawn: Data?
        for _ in 0..<8192 {
            let candidate = try sealLegacy("nonce collision", label: "menstrual-narrative")
            if candidate.first == marker {
                drawn = candidate
                break
            }
        }
        return try #require(drawn, "could not draw a legacy blob starting with \(marker)")
    }

    // MARK: RETIRED FORMAT, v2: the pre-purpose generation (binding-only AAD) is refused by name on
    // the very install that sealed it. Fresh seals have been v3 since the split, so without the
    // hand-built fixture this refusal would be unreachable code no test touches — which is exactly
    // how a deleted branch quietly comes back.
    @Test func v2BlobIsRefusedByNameOnTheSealingInstall() throws {
        let value = "sealed before purposes existed"
        let v2Sealed = try sealV2(value, label: "journal-narrative", binding: installA)
        // v2 layout: version byte + nonce(12) + ciphertext + tag(16) — one byte longer than legacy.
        #expect(v2Sealed.first == ColumnCrypto.deviceBoundFormatVersionV2)
        #expect(v2Sealed.count == 1 + 12 + value.utf8.count + 16)
        for override in [DeviceBindingID.TestOverride.identifier(installA), .identifier(installB), .unavailable] {
            #expect(throws: ColumnCrypto.SealedColumnOpenError.retiredFormat(.v2Marked)) {
                _ = try self.open(v2Sealed, label: "journal-narrative", override: override)
            }
        }
    }

    // MARK: FORMAT BEATS KEYCHAIN STATE, and it must. A v2 row during a transient binding-read
    // outage is still refused as a RETIRED FORMAT rather than as the retryable `ReadError` — the
    // classification happens before any keychain access, so the reader never tells someone to try
    // again over bytes no retry could ever open. The retryable path is V3's alone; see
    // `transientBindingReadErrorIsRetryableAndSelfHeals`, which still holds.
    @Test func v2BlobRefusesByFormatEvenDuringABindingReadError() throws {
        let v2Sealed = try sealV2("retry my v2 row", label: "menstrual-narrative", binding: installA)
        #expect(throws: ColumnCrypto.SealedColumnOpenError.retiredFormat(.v2Marked)) {
            _ = try self.open(v2Sealed, label: "menstrual-narrative", override: .readError)
        }
    }

    // MARK: An EMPTY column is its own named state, never a retired FORMAT. No writer produces
    // `Data()` and every real sealed blob is at least nonce + tag, so empty is a store fault —
    // Phase 2.6's finding, kept here so a corruption can never be counted as a legacy row.
    @Test func anEmptyBlobIsRefusedAsEmptyAndNotAsARetiredFormat() throws {
        #expect(throws: ColumnCrypto.SealedColumnOpenError.emptyBlob) {
            _ = try self.open(Data(), label: "worry-box", override: .identifier(self.installA))
        }
    }

    // MARK: Proves the Codable seal/open pair speaks the same ONE format as the string pair (both
    // route through the shared core), and refuses a retired blob identically.
    @Test func codableSealsAreDeviceBoundAndRefuseRetiredBlobs() throws {
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
        DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            #expect(throws: ColumnCrypto.SealedColumnOpenError.retiredFormat(.unprefixed)) {
                let _: [String]? = try crypto.open(legacy, contentKey: self.contentKey)
            }
        }
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
    // authentication failure that reads like corrupted data, and not as one of the terminal
    // `SealedColumnOpenError` cases — and the same blob must open unchanged once the keychain
    // recovers. This is the distinction `currentForOpen()` exists for, and it survives Phase 3.
    @Test func transientBindingReadErrorIsRetryableAndSelfHeals() throws {
        let sealed = try seal("retry me", label: "journal-narrative", override: .identifier(installA))
        #expect(throws: DeviceBindingID.ReadError.self) {
            _ = try self.open(sealed, label: "journal-narrative", override: .readError)
        }
        let opened = try open(sealed, label: "journal-narrative", override: .identifier(installA))
        #expect(opened == "retry me")
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

    // MARK: The strict seal's output IS the shipping format: version tag, opens on the sealing
    // install, refuses on any other. (Through Phase 2.6 this went through `openReportingRung`; that
    // receipt-bearing dispatch existed only for the format migrator, which Phase 3 deleted along
    // with the rungs it reported, so the assertion runs on the shipping reader now.)
    @Test func strictSealOutputStartsWith0x03AndOpensAsV3() throws {
        let crypto = ColumnCrypto(label: "intimacy-log")
        let plaintext = Data("strictly bound".utf8)
        let sealed = try DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            try crypto.sealPlaintextV3Strict(plaintext, contentKey: contentKey)
        }
        #expect(sealed.first == ColumnCrypto.deviceBoundFormatVersionV3)
        #expect(try open(sealed, label: "intimacy-log", override: .identifier(installA)) == "strictly bound")
        #expect(throws: (any Error).self) {
            _ = try self.open(sealed, label: "intimacy-log", override: .identifier(self.installB))
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
