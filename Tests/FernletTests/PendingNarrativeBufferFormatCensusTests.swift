// PendingNarrativeBufferFormatCensusTests.swift
// FernletTests
//
// Phase 0 of Docs/Plan-Crypto-Standardization-2026-08-27.md, PendingNarrativeBuffer surface: the
// census must produce a trustworthy count of legacy buffer blobs WITHOUT writing, without the
// buffer key, and without ever reporting an unreadable file as a clean zero.

import CryptoKit
import FernletFoundation
import Foundation
import PrivateStoreCore
import Security
import Testing

/// Tests for ``PendingNarrativeBufferFormatCensus`` — the read-only, key-free classifier that
/// answers "is there still a pre-`91c3956` legacy pending-narrative blob on this device?".
///
/// Two properties are load-bearing here, and neither is about convenience:
///
/// 1. **The census must be right about legacy bytes**, because Phase 3 of the plan deletes
///    `PendingNarrativeBuffer.loadEntries()`'s legacy branch once the count is observed at zero.
///    A census that mislabels a legacy file as clean would license deleting the only code that can
///    open a tester's cycle notes. So this suite plants a byte-exact legacy file — and then proves
///    it is byte-exact the only way that can be proven: by having the **shipping legacy reader**
///    open it. That is also the first coverage this repo has ever had of that branch; before this
///    file, no legacy fixture existed anywhere.
/// 2. **The census must not write.** A "census" that created the buffer directory, or minted the
///    buffer key by asking for it, would perturb exactly the state it is measuring — and minting
///    the key is not hypothetical: `PendingNarrativeBuffer.bufferKey()` creates and stores one on
///    first use, so merely *reaching for* the key is a keychain write. The read-only tests below
///    snapshot bytes, directory listings and the keychain slot around each call.
///
/// Isolation: every test takes its own `uniqueNarrativeBufferScope()` (throwaway directory AND
/// throwaway keychain service, which ride together because the buffer is sealed), removes the
/// directory, and sweeps the service — so a parallel suite's buffer is never touched.
struct PendingNarrativeBufferFormatCensusTests {

    // MARK: - Fixture constants

    /// The account the buffer files its 256-bit key under, pinned here as a literal because it is
    /// `private` inside `PendingNarrativeBuffer`. The tests use it for two things the census's whole
    /// value rests on: planting a known key so the shipping legacy reader can open the planted
    /// fixture, and asserting the census left the slot **empty** on scopes where no key was planted.
    private static let bufferKeyAccountV2 = "com.fernlet.buffer.key.v2"

    /// Named bound on the fixture's re-seal loop below. Each draw fails with probability 2⁻³², so
    /// eight is already absurd headroom; the bound exists so the loop cannot be unbounded, not
    /// because it is expected to iterate.
    private static let maximumNonceDraws = 8

    /// Thrown when the fixture builder somehow draws `maximumNonceDraws` nonces that all begin with
    /// the v2 marker. Reaching this means the RNG is broken, not that the test is flaky.
    private struct ImplausibleNonceCollision: Error {}

    // MARK: - Fixtures

    /// Payloads shaped like the real thing: a locked-state cycle note with symptom bytes, plus one
    /// bare entry. Content matters only in that the legacy fixture must be a genuine JSON array of
    /// `PendingNarrativePayload`, so the legacy reader can decode it after opening the box.
    private func fixturePayloads() -> [PendingNarrativePayload] {
        [
            PendingNarrativePayload(
                hkExternalUUID: "6C0F4E1A-0000-4000-8000-00000000CE01",
                dateKey: "2026-08-20",
                noteBytes: Data("cramps in the evening".utf8),
                symptomFlagsBytes: Data([0b0000_0011]),
                customSymptomScalesBytes: nil
            ),
            PendingNarrativePayload(
                hkExternalUUID: "6C0F4E1A-0000-4000-8000-00000000CE02",
                dateKey: "2026-08-21",
                noteBytes: nil,
                symptomFlagsBytes: nil,
                customSymptomScalesBytes: nil
            )
        ]
    }

    /// Bytes byte-identical to what a **pre-`91c3956`** `saveEntries(_:)` wrote: `JSONEncoder` over
    /// the payload array, `ChaChaPoly.seal(plaintext, using: key)` with **no** associated data, and
    /// the box's `combined` form (nonce ‖ ciphertext ‖ tag) written straight to disk with **no**
    /// prefix. That is the whole legacy format — see `git show 91c3956` for the diff that added the
    /// `FNB2` prefix and the `pendingNarrativeBufferV2` AAD on top of it.
    ///
    /// The seal call is deliberately the old one verbatim, random nonce and all, rather than a
    /// hand-assembled blob: a fixture that is only *shaped* like the old format would prove nothing
    /// about the reader. The bounded re-draw exists solely so the fixture cannot accidentally begin
    /// with the four marker bytes and turn a legacy assertion into a confusing v2 result — the
    /// 2⁻³² collision the census documents as an accepted limit is exercised deliberately, in its
    /// own test below, not by luck here.
    private func legacyFileBytes(under key: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(fixturePayloads())
        for _ in 0..<Self.maximumNonceDraws {
            let combined = try ChaChaPoly.seal(plaintext, using: key).combined
            if !combined.starts(with: PendingNarrativeBufferFormatCensus.versionTwoMarker) {
                return combined
            }
        }
        throw ImplausibleNonceCollision()
    }

    /// Creates the scope's directory (the buffer's own first write is what normally creates it) and
    /// writes `bytes` at the one path the buffer reads, returning that path.
    @discardableResult
    private func plant(_ bytes: Data, in scope: PendingNarrativeStorageScope) throws -> URL {
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true)
        let url = PendingNarrativeBuffer.fileURL(in: scope.directory)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Removes both halves of a throwaway scope's state. Both halves, always: a leaked keychain row
    /// outlives the test process's temporary directory.
    private func cleanUp(_ scope: PendingNarrativeStorageScope) {
        try? FileManager.default.removeItem(at: scope.directory)
        KeychainItem.deleteAll(service: scope.keychainService)
    }

    /// The scope's directory as a sorted listing, or `nil` when the directory does not exist — the
    /// snapshot the read-only assertions compare across a census call.
    private func listing(of scope: PendingNarrativeStorageScope) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: scope.directory.path).sorted()
    }

    // MARK: - The legacy bucket

    /// A byte-exact legacy file is counted as legacy — the finding the whole Phase-0 census exists
    /// to produce, and the one that must never be a false negative.
    @Test func aPlantedLegacyFileIsCountedAsLegacy() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let planted = try plant(try legacyFileBytes(under: SymmetricKey(size: .bits256)), in: scope)

        let census = PendingNarrativeBufferFormatCensus.take(of: scope)

        #expect(census.format == .legacyUnprefixed)
        #expect(census.fileURL == planted, "the census must report on the file the buffer itself reads")
        #expect(census.legacyCount == 1)
        #expect(census.versionTwoCount == 0)
        #expect(census.indeterminateCount == 0)
        #expect(
            !census.isProvenLegacyFree,
            "a device holding a legacy blob is not proven clean — Phase 3 is gated on this being false"
        )
    }

    /// The fixture is not merely legacy-*shaped*: the shipping reader's legacy branch opens it and
    /// decodes the payloads back.
    ///
    /// This is the byte-exactness proof. `PendingNarrativeBuffer.loadEntries()`'s
    /// `// cryptographic-domain: legacy-read` line had no test anywhere in the repo before this one,
    /// so "the census recognises legacy files" was previously unfalsifiable — the only legacy bytes
    /// in existence were on testers' phones. Planting the key under the scope's throwaway service
    /// (rather than letting the buffer mint one) is what lets the real reader open the real fixture.
    @Test func theLegacyFixtureIsExactlyWhatTheShippingLegacyReaderOpens() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }

        let key = SymmetricKey(size: .bits256)
        let stored = KeychainItem.store(
            key.rawBytes,
            account: Self.bufferKeyAccountV2,
            service: scope.keychainService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        #expect(stored == errSecSuccess, "planting the buffer key failed; the fixture cannot be opened")
        try plant(try legacyFileBytes(under: key), in: scope)

        // The census's verdict, and the reader's behaviour on the same bytes, must agree.
        #expect(PendingNarrativeBufferFormatCensus.take(of: scope).format == .legacyUnprefixed)

        let drained = try PendingNarrativeBuffer(scope: scope).drainAll()
        #expect(drained.count == 2)
        #expect(drained.first?.hkExternalUUID == "6C0F4E1A-0000-4000-8000-00000000CE01")
        #expect(drained.first?.noteBytes == Data("cramps in the evening".utf8))
        #expect(drained.last?.dateKey == "2026-08-21")
    }

    /// Bytes far too short to be any ChaChaPoly box still land in the legacy bucket, because the
    /// marker is the *only* rule — exactly as in the reader, which would strip nothing, hand the
    /// scribble to `ChaChaPoly.SealedBox(combined:)` and throw.
    ///
    /// This pins the documented limit rather than a desirable behavior: corrupt bytes are
    /// indistinguishable from legacy bytes by marker alone, so ``legacyCount`` is an upper bound.
    /// That is the safe direction — an over-count delays the Phase-3 deletion; an under-count would
    /// authorize it wrongly.
    @Test func bytesTooShortToBeABoxLandInTheLegacyBucket() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        try plant(Data([0x01, 0x02, 0x03]), in: scope)

        let census = PendingNarrativeBufferFormatCensus.take(of: scope)

        #expect(census.format == .legacyUnprefixed)
        #expect(census.legacyCount == 1)
        #expect(!census.isProvenLegacyFree)
    }

    /// The accepted 2⁻³² caveat, made explicit: a legacy box whose first four **nonce** bytes happen
    /// to spell `FNB2` is classified v2.
    ///
    /// Pinned deliberately. The census is defined as "what `loadEntries()` will decide", and the
    /// reader would make the same call on these bytes (strip four, attempt a v2 open with the AAD,
    /// throw). Engineering around the collision would make the census disagree with the code it
    /// measures, which is worse than a one-in-four-billion miscount. If this test ever starts
    /// failing, the classification rule has diverged from the reader's — that is the alarm.
    @Test func aNonceSpellingTheMarkerIsClassifiedTheWayTheReaderWouldClassifyIt() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }

        let nonceBytes = PendingNarrativeBufferFormatCensus.versionTwoMarker + Data(repeating: 0x5A, count: 8)
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let plaintext = try JSONEncoder().encode(fixturePayloads())
        let colliding = try ChaChaPoly.seal(plaintext, using: SymmetricKey(size: .bits256), nonce: nonce).combined
        try plant(colliding, in: scope)

        #expect(PendingNarrativeBufferFormatCensus.take(of: scope).format == .v2Marked)
    }

    // MARK: - The v2 bucket

    /// What the production writer writes is what the census calls v2 — the cross-check that keeps
    /// the census honest about the *current* format, not just a remembered one.
    ///
    /// Driven through the public `append(_:)` API rather than by planting bytes, so the marker,
    /// the AAD binding and the file path all come from the shipping code path.
    @Test func whatTheProductionWriterWritesIsCountedAsVersionTwo() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }

        let buffer = PendingNarrativeBuffer(scope: scope)
        try buffer.append(fixturePayloads()[0])

        let census = PendingNarrativeBufferFormatCensus.take(of: scope)

        #expect(census.format == .v2Marked)
        #expect(census.versionTwoCount == 1)
        #expect(census.legacyCount == 0)
        #expect(census.isProvenLegacyFree)

        // The on-disk shape itself, pinned: four cleartext ASCII bytes at offset 0. The census
        // re-exports the writer's own constant, so this asserts the shared constant is still what
        // the format document says it is — not that two copies happen to agree.
        #expect(PendingNarrativeBufferFormatCensus.versionTwoMarker == Data("FNB2".utf8))
        #expect(PendingNarrativeBufferFormatCensus.versionTwoMarker.count == 4)
        let raw = try Data(contentsOf: PendingNarrativeBuffer.fileURL(in: scope.directory))
        #expect(raw.starts(with: PendingNarrativeBufferFormatCensus.versionTwoMarker))
    }

    // MARK: - Absent and empty: the two legitimate zeros

    /// No file is `absent` — a real, positive zero — and emphatically not `legacy`, not an error,
    /// and not indeterminate.
    ///
    /// This is the **common** case: a user who never logged a cycle note while the app lock was
    /// engaged never causes the buffer file to exist. If absence were reported as anything else,
    /// the Phase-0 number would be noise on almost every device.
    @Test func anAbsentFileIsAbsentNotLegacyAndNotAnError() {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }

        let census = PendingNarrativeBufferFormatCensus.take(of: scope)

        #expect(census.format == .absent)
        #expect(census.legacyCount == 0)
        #expect(census.indeterminateCount == 0)
        #expect(census.isProvenLegacyFree, "absence is evidence of a clean surface, unlike unreadability")
    }

    /// A zero-byte file is its own bucket, matching `loadEntries()`'s explicit `encrypted.isEmpty`
    /// short-circuit. It is legacy-free, but it is not the same fact as `absent` — the buffer's
    /// atomic write never produces an empty file, so a device reporting this has something else
    /// going on and should not be summarised as "never used the buffer".
    @Test func anEmptyFileIsItsOwnBucket() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        try plant(Data(), in: scope)

        let census = PendingNarrativeBufferFormatCensus.take(of: scope)

        #expect(census.format == .empty)
        #expect(census.legacyCount == 0)
        #expect(census.versionTwoCount == 0)
        #expect(census.isProvenLegacyFree)
    }

    /// Unreadability is indeterminate, not clean: ``PendingNarrativeBufferFormatCensus/Format/unreadable(reason:)``
    /// reports **no** count at all (`nil`, not `0`) and refuses to call the surface proven.
    ///
    /// The real trigger is `URLFileProtection.complete` denying a read while the *device* is locked
    /// (Fernlet's own app lock is irrelevant — the buffer exists to be written while that lock is
    /// engaged). A simulator test cannot lock the device, so the reading is constructed directly
    /// through the public initializer; what is under test here is the scoring rule, which is the
    /// half that could silently manufacture a false "census = 0" proof for Phase 3.
    @Test func anUnreadableFileIsIndeterminateAndNeverAProvenZero() {
        let scope = uniqueNarrativeBufferScope()
        let reading = PendingNarrativeBufferFormatCensus(
            format: .unreadable(reason: "Operation not permitted"),
            fileURL: PendingNarrativeBuffer.fileURL(in: scope.directory)
        )

        #expect(reading.format.isUnreadable)
        #expect(reading.isIndeterminate)
        #expect(
            reading.legacyCount == nil,
            "an unreadable file must not report a legacy count of 0 — a summed total would swallow it as clean"
        )
        #expect(reading.versionTwoCount == nil)
        #expect(reading.indeterminateCount == 1)
        #expect(
            !reading.isProvenLegacyFree,
            "\"we could not look\" must never score the same as \"we looked and it was clean\""
        )
    }

    // MARK: - Read-only proof

    /// The census writes nothing: not the file it reads, not the directory around it, not the
    /// keychain slot it deliberately never consults.
    ///
    /// Three snapshots, taken around two census calls (the second call also proves the census does
    /// not "helpfully" heal or rewrite on a repeat visit, the way an eager migrator would):
    /// the file's exact bytes, the directory listing (a stray temp file or sidecar would show up
    /// here), and the buffer-key slot — which must still be **empty**, because asking
    /// `PendingNarrativeBuffer` for its key mints one, and a census that minted a key would have
    /// written to the keychain of every device it ran on.
    @Test func theCensusIsAReadOnlySnapshotAndNeverMintsTheBufferKey() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let url = try plant(try legacyFileBytes(under: SymmetricKey(size: .bits256)), in: scope)

        let bytesBefore = try Data(contentsOf: url)
        let listingBefore = listing(of: scope)
        #expect(
            KeychainItem.load(account: Self.bufferKeyAccountV2, service: scope.keychainService) == nil,
            "precondition: this scope has no buffer key yet"
        )

        let first = PendingNarrativeBufferFormatCensus.take(of: scope)
        let second = PendingNarrativeBufferFormatCensus.take(of: scope)

        let bytesAfter = try Data(contentsOf: url)

        #expect(first == second, "two readings of an untouched file must agree — the census is a pure read")
        #expect(bytesAfter == bytesBefore, "the census rewrote the file it was only meant to read")
        #expect(listing(of: scope) == listingBefore, "the census left something behind in the scope directory")
        #expect(
            KeychainItem.load(account: Self.bufferKeyAccountV2, service: scope.keychainService) == nil,
            "the census minted the buffer key — classification must be key-free, and minting is a WRITE"
        )
    }

    /// Censusing a scope that has never been used creates nothing — no directory, no file.
    ///
    /// Worth its own test because the buffer's `saveEntries(_:)` *does* call
    /// `createDirectory(withIntermediateDirectories:)`, so the wrong seam reused here would leave an
    /// empty `Application Support/Fernlet` on a device that never buffered a note, and the census
    /// would be observably changing the state it reports on.
    @Test func censusingAnAbsentFileCreatesNothing() {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        #expect(listing(of: scope) == nil, "precondition: the throwaway scope's directory does not exist yet")

        _ = PendingNarrativeBufferFormatCensus.take(of: scope)

        #expect(
            !FileManager.default.fileExists(atPath: scope.directory.path),
            "the census created the scope directory it was only meant to look inside"
        )
        #expect(
            !FileManager.default.fileExists(atPath: PendingNarrativeBuffer.fileURL(in: scope.directory).path),
            "the census created the buffer file it was only meant to classify"
        )
    }

    /// The directory-only entry point classifies the same file as the scope entry point, so a
    /// diagnostic holding only a path cannot end up reporting on a different file than the buffer
    /// reads.
    @Test func theDirectoryEntryPointAgreesWithTheScopeEntryPoint() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        try plant(try legacyFileBytes(under: SymmetricKey(size: .bits256)), in: scope)

        #expect(
            PendingNarrativeBufferFormatCensus.take(inDirectory: scope.directory)
                == PendingNarrativeBufferFormatCensus.take(of: scope)
        )
    }
}
