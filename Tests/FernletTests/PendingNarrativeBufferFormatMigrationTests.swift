// PendingNarrativeBufferFormatMigrationTests.swift
// FernletTests
//
// Phase 2.4 of Docs/Plan-Crypto-Standardization-2026-08-27.md: the pre-`91c3956` bare-box →
// `FNB2`+AAD format migrator for the locked-note pending buffer
// (`PendingNarrativeBufferFormatMigrator`).
//
// What these tests have to establish, because Phase 3 deletes the legacy reader on the strength
// of the corpus this migrator retires:
//   1. A byte-exact legacy file is converted through the REAL paths — opened by the shipping
//      legacy branch, re-sealed by the shipping v2 seal — and the re-seal genuinely binds the
//      `pendingNarrativeBufferV2` domain (an unauthenticated open of the new body FAILS), it
//      does not relabel.
//   2. ONE key value is pinned through the convert: the buffer-key keychain row is byte-identical
//      around every pass, a keyless pass never mints a row, and the confirming/latching pass
//      never fetches the key at all (marker-only classification).
//   3. Every blocked state — unreadable file, missing key, corrupt bytes, failed write — keeps
//      the latch closed, makes no forward progress, and leaves every source byte in place;
//      migrator and census always agree the surface is not clean.
//   4. Absence is an EARNED zero on this transient drained-and-purged surface: a pass over an
//      absent file latches while writing nothing anywhere — no directory, no file, no key.
//
// The wipe wall (design §8 item 14) is the walls themselves: the
// `com.fernlet.private-store.pendingNarrativeBufferMigrationComplete` disposition row in
// `PersistedSurfaceWipeBoundaryTests` and the manifest token in `PrivacyWipeCoverageTests` land
// in the same change as the key. Funnel-EFFECT observation carries the same recorded testability
// residual as the 2.1/2.2 latches (the hook closure closes over the production lock service);
// `latchIsOneWayFailClosedAndResettable` covers the reset mechanics.
//
// Isolation: every test takes its own `uniqueNarrativeBufferScope()` (throwaway directory AND
// throwaway keychain service, cleaned up in both halves), plus an isolated `UserDefaults` suite
// per test so no latch state ever touches the device's real completion bit. The suite is
// `@MainActor` because the migrator is (the isolated conformance is the design's compile-enforced
// answer to the lost-update race with the lock service's buffer instance).

import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import PrivateStoreCore
import Security
import Testing

@MainActor
struct PendingNarrativeBufferFormatMigrationTests {

    // MARK: - Fixture constants

    /// The account the buffer files its 256-bit key under, pinned as a literal because it is
    /// `private` inside `PendingNarrativeBuffer` (the census suite's idiom). Used to plant a known
    /// key so the shipping reader can open fixtures, and to assert the slot's exact bytes around
    /// every pass — the pinned-key proof.
    private static let bufferKeyAccountV2 = "com.fernlet.buffer.key.v2"

    /// Named bound on the fixture's re-seal loop below. Each draw fails with probability 2⁻³², so
    /// eight is already absurd headroom; the bound exists so the loop cannot be unbounded.
    private static let maximumNonceDraws = 8

    /// Thrown when the fixture builder somehow draws `maximumNonceDraws` nonces that all begin
    /// with the v2 marker. Reaching this means the RNG is broken, not that the test is flaky.
    private struct ImplausibleNonceCollision: Error {}

    // MARK: - Fixtures

    /// Payloads shaped like the real thing: a locked-state cycle note with symptom bytes, plus one
    /// bare entry — the census suite's fixture, reused so the two suites plant the same corpus.
    private func fixturePayloads() -> [PendingNarrativePayload] {
        [
            PendingNarrativePayload(
                hkExternalUUID: "6C0F4E1A-0000-4000-8000-00000000AE01",
                dateKey: "2026-08-20",
                noteBytes: Data("cramps in the evening".utf8),
                symptomFlagsBytes: Data([0b0000_0011]),
                customSymptomScalesBytes: nil
            ),
            PendingNarrativePayload(
                hkExternalUUID: "6C0F4E1A-0000-4000-8000-00000000AE02",
                dateKey: "2026-08-21",
                noteBytes: nil,
                symptomFlagsBytes: nil,
                customSymptomScalesBytes: nil
            )
        ]
    }

    /// Bytes byte-identical to what a **pre-`91c3956`** `saveEntries(_:)` wrote: `JSONEncoder`
    /// over the payload array, `ChaChaPoly.seal(plaintext, using: key)` with **no** associated
    /// data, and the box's `combined` form written straight to disk with **no** prefix. The
    /// bounded re-draw keeps a 2⁻³² nonce accident from turning a legacy fixture into a
    /// confusing v2 result.
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

    /// Creates the scope's directory (the buffer's own first write is what normally creates it)
    /// and writes `bytes` at the one path the buffer reads, returning that path.
    @discardableResult
    private func plant(_ bytes: Data, in scope: PendingNarrativeStorageScope) throws -> URL {
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true)
        let url = PendingNarrativeBuffer.fileURL(in: scope.directory)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Files `key` where the buffer looks for it, so the shipping reader can open a planted
    /// fixture and the convert's non-minting load finds a row to pin.
    private func plantBufferKey(_ key: SymmetricKey, in scope: PendingNarrativeStorageScope) {
        let status = KeychainItem.store(
            key.rawBytes,
            account: Self.bufferKeyAccountV2,
            service: scope.keychainService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        #expect(status == errSecSuccess, "planting the buffer key failed; the fixture cannot be opened")
    }

    /// The buffer-key slot's exact bytes, or nil when the slot is empty — the snapshot the
    /// pinned-key assertions compare across passes.
    private func keyRowBytes(in scope: PendingNarrativeStorageScope) -> Data? {
        KeychainItem.load(account: Self.bufferKeyAccountV2, service: scope.keychainService)
    }

    /// Removes both halves of a throwaway scope's state. Both halves, always: a leaked keychain
    /// row outlives the test process's temporary directory.
    private func cleanUp(_ scope: PendingNarrativeStorageScope) {
        try? FileManager.default.removeItem(at: scope.directory)
        KeychainItem.deleteAll(service: scope.keychainService)
    }

    /// An isolated defaults suite so a test never reads or writes the device's real latch. The
    /// suite name comes back so the test can remove the persistent domain when it finishes.
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let name = "PendingNarrativeBufferFormatMigrationTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// A migrator over `scope` whose latch rides `defaults` — never `.standard`.
    private func makeMigrator(
        scope: PendingNarrativeStorageScope,
        defaults: UserDefaults
    ) -> PendingNarrativeBufferFormatMigrator {
        PendingNarrativeBufferFormatMigrator(
            scope: scope,
            latch: PendingNarrativeBufferMigrationLatch(defaults: defaults)
        )
    }

    // MARK: - Conversion

    /// T1: the finding the whole migrator exists to produce. A byte-exact legacy file is
    /// converted through the shipping paths, drains back field-for-field, the buffer-key row is
    /// byte-identical around the pass (the pinned-key pin: the convert cannot mint or rewrite the
    /// key even when the key IS present), and the old no-AAD shape genuinely no longer opens —
    /// the new box is AAD-bound, not a re-wrapped bare box.
    @Test func aPlantedLegacyBufferIsConvertedAndTheLegacyShapeNoLongerOpens() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        plantBufferKey(key, in: scope)
        let keyRowBefore = keyRowBytes(in: scope)
        let planted = try plant(try legacyFileBytes(under: key), in: scope)

        let result = makeMigrator(scope: scope, defaults: defaults).performPass()

        #expect(result.examined == 1)
        #expect(result.converted == 1)
        #expect(result.madeForwardProgress)
        #expect(!result.isClean, "a pass that CONVERTED is a finding, never a proof of clean")

        #expect(PendingNarrativeBufferFormatCensus.take(of: scope).format == .v2Marked)
        let raw = try Data(contentsOf: planted)
        #expect(raw.starts(with: PendingNarrativeBufferFormatCensus.versionTwoMarker))

        // Fidelity through conversion, through the shipping reader.
        let drained = try PendingNarrativeBuffer(scope: scope).drainAll()
        #expect(drained == fixturePayloads(), "the converted file must decode to exactly the entries the legacy file held")

        // The pinned-key pin, asserted rather than assumed.
        #expect(keyRowBytes(in: scope) == keyRowBefore, "the convert rewrote or re-minted the buffer key")

        // The old format no longer opens: stripping the marker and attempting the legacy no-AAD
        // open under the same key must fail, because the new box is bound to the v2 purpose.
        let strippedBody = raw.dropFirst(PendingNarrativeBufferFormatCensus.versionTwoMarker.count)
        #expect(throws: (any Error).self, "the re-sealed body still opens as a bare legacy box — the convert relabeled instead of re-sealing") {
            _ = try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: strippedBody), using: key)
        }
    }

    /// T2: the shared loop's happy path — pass 1 converts, pass 2 confirms, the latch is set.
    @Test func runConvertsThenLatchesOnTheConfirmingPass() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        plantBufferKey(key, in: scope)
        try plant(try legacyFileBytes(under: key), in: scope)

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        #expect(migrator.run() == true)
        #expect(PendingNarrativeBufferMigrationLatch(defaults: defaults).isComplete)
        #expect(PendingNarrativeBufferFormatCensus.take(of: scope).format == .v2Marked)
    }

    /// T3: idempotence, pinned as byte equality — stronger than a "no-op" tally, because a pass
    /// over a `.v2Marked` file is census-only: it never opens the file body, never fetches the
    /// key, never writes.
    @Test func secondPassOverAConvertedFileIsAByteIdenticalNoOp() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        plantBufferKey(key, in: scope)
        let planted = try plant(try legacyFileBytes(under: key), in: scope)

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        #expect(migrator.performPass().converted == 1, "precondition: the first pass converts")
        let bytesAfterConvert = try Data(contentsOf: planted)
        let keyRowAfterConvert = keyRowBytes(in: scope)

        let second = migrator.performPass()

        #expect(second.isClean)
        #expect(second.examined == 1)
        #expect(second.converted == 0)
        #expect(second.alreadyCurrent == 1)
        #expect(try Data(contentsOf: planted) == bytesAfterConvert, "the confirming pass rewrote a file it should only classify")
        #expect(keyRowBytes(in: scope) == keyRowAfterConvert, "the confirming pass touched the buffer-key row")
    }

    // MARK: - The legitimate zeros

    /// T4: absence is an EARNED zero on this transient drained-and-purged surface, and a clean
    /// pass over it writes nothing anywhere — no directory, no file, no keychain row (the
    /// census-read-only proof, inherited).
    @Test func anAbsentFileIsAnEarnedZeroThatLatchesWithoutCreatingOrMintingAnything() {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        #expect(migrator.run() == true)
        #expect(PendingNarrativeBufferMigrationLatch(defaults: defaults).isComplete)
        #expect(
            migrator.performPass() == PendingNarrativeBufferMigrationResult(),
            "an absent file's tally is all zeros, examined included — the design table's `.absent` row"
        )
        #expect(!FileManager.default.fileExists(atPath: scope.directory.path), "the pass created the scope directory")
        #expect(
            !FileManager.default.fileExists(atPath: PendingNarrativeBuffer.fileURL(in: scope.directory).path),
            "the pass created the buffer file it was only meant to look for"
        )
        #expect(keyRowBytes(in: scope) == nil, "a clean pass minted the buffer key — classification must be key-free")
    }

    /// T5: the other two legacy-free readings. An empty file latches while ticking only
    /// `examined` (the design table's `.empty` row — `isClean` ignores `examined`), and what the
    /// production writer writes latches as `alreadyCurrent` with the bytes untouched.
    @Test func emptyAndV2FilesLatchWithoutTouchingKeyOrBytes() throws {
        // (a) A zero-byte file: legacy-free by the reader's own short-circuit, left alone.
        let emptyScope = uniqueNarrativeBufferScope()
        defer { cleanUp(emptyScope) }
        let (emptyDefaults, emptySuite) = makeDefaults()
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }

        let plantedEmpty = try plant(Data(), in: emptyScope)
        let emptyMigrator = makeMigrator(scope: emptyScope, defaults: emptyDefaults)
        #expect(emptyMigrator.run() == true)
        #expect(
            emptyMigrator.performPass() == PendingNarrativeBufferMigrationResult(examined: 1),
            "an empty file ticks examined and nothing else — it is not the migration target, so it is not alreadyCurrent"
        )
        #expect(try Data(contentsOf: plantedEmpty).isEmpty, "the pass wrote into (or deleted) the empty file")
        #expect(keyRowBytes(in: emptyScope) == nil, "an empty-file pass fetched (and minted) the buffer key")

        // (b) A genuine v2 file born through the shipping writer.
        let v2Scope = uniqueNarrativeBufferScope()
        defer { cleanUp(v2Scope) }
        let (v2Defaults, v2Suite) = makeDefaults()
        defer { v2Defaults.removePersistentDomain(forName: v2Suite) }

        try PendingNarrativeBuffer(scope: v2Scope).append(fixturePayloads()[0])
        let v2URL = PendingNarrativeBuffer.fileURL(in: v2Scope.directory)
        let v2Bytes = try Data(contentsOf: v2URL)

        let v2Migrator = makeMigrator(scope: v2Scope, defaults: v2Defaults)
        let tally = v2Migrator.performPass()
        #expect(tally.examined == 1)
        #expect(tally.alreadyCurrent == 1)
        #expect(v2Migrator.run() == true)
        #expect(try Data(contentsOf: v2URL) == v2Bytes, "a v2 file must come through byte-identical")
    }

    // MARK: - Blocked states

    /// T6: "could not look" blocks — and costs only a retry. An unreadable file is indeterminate
    /// (never unconvertible: a read failure has no answer to "is this still legacy?"), and once
    /// readable again the same corpus converts and drains intact.
    @Test func anUnreadableFileBlocksTheLatch() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        plantBufferKey(key, in: scope)
        let planted = try plant(try legacyFileBytes(under: key), in: scope)

        // Deny read while `fileExists` stays true — the closest a test can get to data
        // protection with the device locked (the OwnPhoto suite's idiom). Restored below so the
        // cleanup can still remove the file.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: planted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: planted.path) }

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        let blocked = migrator.performPass()
        #expect(blocked.indeterminate == 1)
        #expect(blocked.unconvertible == 0, "\"could not look\" must never be scored as \"nothing opens these bytes\"")
        #expect(!blocked.isClean)
        #expect(migrator.run() == false)
        #expect(!PendingNarrativeBufferMigrationLatch(defaults: defaults).isComplete)

        // Fail-closed costs only a retry: readable again, the pass converts and the notes survive.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: planted.path)
        #expect(migrator.run() == true)
        #expect(try PendingNarrativeBuffer(scope: scope).drainAll() == fixturePayloads())
    }

    /// T7: a missing buffer key is indeterminate — not "corrupt" — and the pass NEVER mints one:
    /// the convert's single key fetch is the non-minting load, and minting is a delete-then-add
    /// keychain WRITE that would destroy the real key on a device where the row exists.
    @Test func aMissingBufferKeyIsIndeterminateAndNeverMintsOne() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let planted = try plant(try legacyFileBytes(under: SymmetricKey(size: .bits256)), in: scope)
        let bytesBefore = try Data(contentsOf: planted)

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        let result = migrator.performPass()

        #expect(result.indeterminate == 1, "a nil key load cannot distinguish locked from lost — always indeterminate")
        #expect(result.unconvertible == 0)
        #expect(!result.isClean)
        #expect(!result.madeForwardProgress)
        #expect(migrator.run() == false)
        #expect(try Data(contentsOf: planted) == bytesBefore, "a keyless pass touched the file")
        #expect(keyRowBytes(in: scope) == nil, "the pass minted a buffer key — it must use the non-minting load")
    }

    /// T8: corrupt bytes block the latch, loudly and forever — and are never deleted or
    /// rewritten. Migrator and census must AGREE the surface is not clean: the census counts the
    /// same bytes as `.legacyUnprefixed` (its documented upper bound), so a migrator that latched
    /// over them would report "complete" beside a census still reading 1.
    @Test func corruptBytesBlockTheLatchAndAreNeverDeletedOrRewritten() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        plantBufferKey(SymmetricKey(size: .bits256), in: scope)
        let planted = try plant(Data([0x01, 0x02, 0x03]), in: scope)

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        let result = migrator.performPass()

        #expect(result.unconvertible == 1)
        #expect(!result.isClean)
        #expect(!result.madeForwardProgress)
        #expect(migrator.run() == false)
        #expect(!PendingNarrativeBufferMigrationLatch(defaults: defaults).isComplete)
        #expect(try Data(contentsOf: planted) == Data([0x01, 0x02, 0x03]), "corrupt bytes must be left byte-identical")
        #expect(
            PendingNarrativeBufferFormatCensus.take(of: scope).format == .legacyUnprefixed,
            "migrator and census must agree this surface is not clean — the agreement pin"
        )
    }

    /// T9: the realistic "corrupt": ciphertext whose key died. Same fail-closed handling as T8 —
    /// and the bytes survive for a hypothetical future recovery, because "corrupt" may really
    /// mean the last physical copy of someone's cycle notes.
    @Test func bytesSealedUnderALostKeyBlockTheLatchAndSurvive() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        plantBufferKey(SymmetricKey(size: .bits256), in: scope)                 // key A, resident
        let orphaned = try legacyFileBytes(under: SymmetricKey(size: .bits256)) // sealed under key B, lost
        let planted = try plant(orphaned, in: scope)

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        let result = migrator.performPass()

        #expect(result.unconvertible == 1)
        #expect(!result.isClean)
        #expect(!result.madeForwardProgress)
        #expect(migrator.run() == false)
        #expect(try Data(contentsOf: planted) == orphaned, "orphaned ciphertext must survive byte-identical")
        #expect(PendingNarrativeBufferFormatCensus.take(of: scope).format == .legacyUnprefixed)
    }

    /// T10: a failed atomic write blocks the pass and loses nothing — the never-lose-plaintext
    /// ordering: the original file is intact and still opens through the shipping reader.
    @Test func aFailedWriteLeavesTheOriginalBufferOpenable() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        plantBufferKey(key, in: scope)
        let planted = try plant(try legacyFileBytes(under: key), in: scope)
        let bytesBefore = try Data(contentsOf: planted)

        // Read-only directory: the `.atomic` replace cannot land its temp file, so the seal
        // throws with the original untouched. Restored below (and in a defer, for the cleanup).
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scope.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scope.directory.path) }

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        let result = migrator.performPass()

        #expect(result.convertFailures == 1)
        #expect(!result.isClean)
        #expect(!result.madeForwardProgress)
        #expect(migrator.run() == false)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scope.directory.path)
        #expect(try Data(contentsOf: planted) == bytesBefore, "a failed write must leave the file wholly old")
        #expect(try PendingNarrativeBuffer(scope: scope).drainAll() == fixturePayloads(), "the original must still open after a failed convert")
    }

    // MARK: - The latch

    /// T11: the latch is a short-circuit — a latched `run()` funds no pass at all — and its doc
    /// comment's honesty about staleness holds: the census, which never consults the latch, still
    /// reports the truth about an adversarially re-introduced legacy file.
    @Test func runShortCircuitsOnceLatched() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PendingNarrativeBufferMigrationLatch(defaults: defaults).markComplete()
        let planted = try plant(try legacyFileBytes(under: SymmetricKey(size: .bits256)), in: scope)
        let bytesBefore = try Data(contentsOf: planted)

        #expect(makeMigrator(scope: scope, defaults: defaults).run() == true)
        #expect(try Data(contentsOf: planted) == bytesBefore, "a latched run touched the file — the latch must be a pure short-circuit")
        #expect(
            PendingNarrativeBufferFormatCensus.take(of: scope).format == .legacyUnprefixed,
            "the census stays the independent truth a stale latch cannot silence"
        )
    }

    /// T12: the latch contract — absent reads incomplete (fail-closed), `markComplete()` is
    /// one-way until `reset()`, and `reset()` is the unit-testable half of the wipe disposition.
    @Test func latchIsOneWayFailClosedAndResettable() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let latch = PendingNarrativeBufferMigrationLatch(defaults: defaults)
        #expect(!latch.isComplete, "absent must read incomplete — the fail-closed direction")
        latch.markComplete()
        #expect(latch.isComplete)
        latch.reset()
        #expect(!latch.isComplete)
    }

    /// T13: the recorded-decision pin for the read-back-failure aftermath (design §1 step 5 / §6):
    /// the confirming/latching pass classifies a `.v2Marked` file by MARKER ALONE — it never
    /// fetches the key and never opens the body (had it tried, the deleted key row would have
    /// blocked as indeterminate) — so the pass that follows a `.readBackFailed` latches by marker
    /// deliberately, not accidentally. And the honest half of the claim: the file genuinely opens
    /// once the key is back.
    @Test func aV2MarkedFileLatchesByMarkerAloneEvenWhenTheKeyRowIsGone() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanUp(scope) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        plantBufferKey(key, in: scope)
        try PendingNarrativeBuffer(scope: scope).append(fixturePayloads()[0])
        let v2URL = PendingNarrativeBuffer.fileURL(in: scope.directory)
        let v2Bytes = try Data(contentsOf: v2URL)

        KeychainItem.delete(account: Self.bufferKeyAccountV2, service: scope.keychainService)
        #expect(keyRowBytes(in: scope) == nil, "precondition: the key row is gone")

        let migrator = makeMigrator(scope: scope, defaults: defaults)
        let tally = migrator.performPass()
        #expect(tally.alreadyCurrent == 1)
        #expect(tally.isClean, "marker classification must not need the key")
        #expect(migrator.run() == true)
        #expect(PendingNarrativeBufferMigrationLatch(defaults: defaults).isComplete)
        #expect(try Data(contentsOf: v2URL) == v2Bytes)
        #expect(keyRowBytes(in: scope) == nil, "the latching pass fetched (or minted) the key it must never touch")

        // The step-5 claim's honest half: with the key back, the marker-latched file really opens.
        plantBufferKey(key, in: scope)
        #expect(try PendingNarrativeBuffer(scope: scope).drainAll() == [fixturePayloads()[0]])
    }
}
