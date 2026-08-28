// LockWrapFormatMigrationTests.swift
// Fernlet
//
// Phase 2.5 of Docs/Plan-Crypto-Standardization-2026-08-27.md — planted-fixture coverage for
// `LockWrapFormatMigrator`, the legacy→`FLW2` re-wrap of the app lock's scrypt-wrapped content
// key. THE LOCKOUT SURFACE: every failure-injection test here exists to prove one invariant —
// at every instant, including mid-crash at any step, the live row holds a wrap the next passcode
// unlock can open.
//
// Direct-migrator tests drive REAL `FernletLockCrypto` wrap/unwrap closures over a real
// UUID-scoped keychain service (ChaChaPoly needs no scrypt — any 32 bytes serve as the wrapping
// key), so format fidelity is real end-to-end. Service-level tests use the format-faithful
// `FakeLockCryptoProvider` (FLW2-stamped) through `FernletLockService`'s real unlock seam.
// Every test uses its own UUID-scoped service and deletes it afterwards; nothing here may ever
// run against the production keychain service.
//
// T-25 (`updateReportingStatusIsUpdateOnly`) lives here rather than in a KeychainHelpers suite
// because no such suite exists in the tree; it pins the new `KeychainItem.updateReportingStatus`
// seam the promote depends on.

import CryptoKit
import Foundation
import Security
import Testing
import FernletCrypto
import FernletFoundation
import PrivateStoreCore
@testable import FernletLock

@MainActor
@Suite(.serialized)
struct LockWrapFormatMigrationTests {

    // MARK: - Direct migrator: the happy path (T-1, T-2, T-3, T-22, T-23)

    // T-1: one pass converts the planted legacy wrap; the promoted row carries the marker, opens
    // through the REAL reader to the byte-identical content key, and leaves no staging row.
    @Test func legacyWrapConvertsAndNewWrapUnwrapsToIdenticalKey() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)
        #expect(!legacy.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2))

        let result = makeMigrator(service: service).performPass()
        #expect(result.converted == 1)
        #expect(result.failed == 0)
        #expect(result.indeterminate == 0)
        #expect(result.examined == 1)
        #expect(result.madeForwardProgress)

        let row = try #require(KeychainItem.load(for: .wrappedContentKey, service: service))
        #expect(row.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2))
        #expect(try FernletLockCrypto.unwrapContentKey(row, using: Self.wrappingKey) == Self.contentKey)
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil,
                "a clean convert must leave no staging row behind")
    }

    // T-2: the converted row opens through the real `FLW2` branch — which authenticates the
    // registered `lockContentKeyWrapV2` AAD — and FAILS to open as a bare box, proving writer
    // identity and that no new purpose/AAD was smuggled in.
    @Test func convertedRowBindsTheRegisteredV2PurposeVerbatim() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        _ = try Self.plantLegacyRow(service: service)
        #expect(makeMigrator(service: service).performPass().converted == 1)

        let row = try #require(KeychainItem.load(for: .wrappedContentKey, service: service))
        // The real reader's FLW2 branch (AAD authenticated) opens it…
        #expect(try FernletLockCrypto.unwrapContentKey(row, using: Self.wrappingKey) == Self.contentKey)
        // …and the marker-stripped body refuses to open WITHOUT the AAD: the purpose really is
        // bound into the ciphertext, not merely prefixed onto it.
        let body = row.dropFirst(FernletLockCrypto.wrappedContentKeyFormatV2.count)
        let openedWithoutAAD: Data? = (try? ChaChaPoly.SealedBox(combined: body)).flatMap { box in
            try? ChaChaPoly.open(box, using: SymmetricKey(data: Self.wrappingKey))
        }
        #expect(openedWithoutAAD == nil, "the converted box must not open as a bare (AAD-less) box")
    }

    // T-3: idempotence — a second pass over the already-converted row is a clean read-only no-op.
    @Test func secondPassOverAV2RowIsACleanNoOp() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        _ = try Self.plantLegacyRow(service: service)
        #expect(makeMigrator(service: service).performPass().converted == 1)
        let before = try #require(KeychainItem.load(for: .wrappedContentKey, service: service))

        let second = makeMigrator(service: service).performPass()
        #expect(second.alreadyCurrent == 1)
        #expect(second.converted == 0)
        #expect(second.isClean)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == before,
                "an idempotent pass must leave the row byte-identical")
    }

    // T-22: the promote touched only kSecValueData, so the live row keeps the production
    // accessibility class and stays non-synchronizable after conversion.
    @Test func promotePreservesAccessibilityAttributes() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        _ = try Self.plantLegacyRow(service: service)
        #expect(makeMigrator(service: service).performPass().converted == 1)

        let attrs = Self.rowAttributes(account: LockKeychainKey.wrappedContentKey.rawValue, service: service)
        #expect(attrs?.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                "the promote must preserve WhenUnlockedThisDeviceOnly")
        #expect(attrs?.synchronizable == false, "the promote must preserve non-synchronizable")
    }

    // T-23: the Phase-0 census reads zero after a conversion — and a successful pass never
    // produces the indeterminate `nil`.
    @Test func censusReadsZeroAfterConversion() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        _ = try Self.plantLegacyRow(service: service)
        #expect(makeMigrator(service: service).performPass().converted == 1)

        let report = LockWrapFormatCensus.inspect(service: service)
        #expect(report.state == .v2Marked)
        #expect(report.legacyWrapCount == 0)
        #expect(!report.isIndeterminate)
    }

    // MARK: - Direct migrator: no-ops and blockers (T-4, T-5, T-6, T-7)

    // T-4: an absent row is an earned not-applicable — a clean pass with zero writes of any kind.
    @Test func absentRowIsAnEarnedNoOp() {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }

        let result = makeMigrator(service: service).performPass()
        #expect(result.notApplicable == 1)
        #expect(result.examined == 0)
        #expect(result.isClean)
        #expect(KeychainItem.loadAll(service: service).isEmpty,
                "an absent-row pass must create nothing — no staging row, no live row")
    }

    // T-5: an EMPTY row (plantable only outside the house store seam, which refuses empty
    // payloads) blocks as indeterminate, is never touched, and is audited loudly.
    @Test func malformedEmptyRowBlocksAndIsNeverTouched() {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        #expect(Self.plantEmptyRowOutsideTheHouseSeam(service: service) == errSecSuccess)

        let result = makeMigrator(service: service).performPass()
        #expect(result.indeterminate == 1)
        #expect(!result.isClean)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == Data(),
                "the empty row must be left byte-identical (empty), never converted or deleted")
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil)
        #expect(audit.contains("lock.wrapRewrapBlocked", where: { $0["state"] == "malformedEmpty" }))
    }

    // T-6: an unreadable row blocks without writing — "could not look" never reads as clean.
    // This is ALSO the executable pin that S0 classifies over the migrator's INJECTED read and
    // never regresses to the census's public live-read `inspect(service:)`: a REAL legacy row is
    // planted underneath, so a pass that bypassed the injected `.unreadable` seam would convert
    // it and fail the byte-identity assertion.
    @Test func unreadableRowBlocksWithoutWriting() throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)

        let unreadableLoad: (LockKeychainKey, String) -> KeychainItem.ReadResult = { key, svc in
            guard key == .wrappedContentKey else {
                return KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
            }
            return .unreadable(errSecInteractionNotAllowed)
        }
        let result = makeMigrator(service: service, loadRow: unreadableLoad).performPass()
        #expect(result.indeterminate == 1)
        #expect(!result.isClean)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy,
                "an unreadable classification must leave the real row untouched")
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil)
        #expect(audit.contains("lock.wrapRewrapBlocked", where: { $0["state"] == "unreadable" }))
    }

    // T-7: census and migrator agree on every fixture — classification is single-sourced in
    // `LockWrapFormatCensus.classify`, pinned anyway.
    @Test func censusAndMigratorAgreeOnEveryFixture() throws {
        // Absent ↔ notApplicable.
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            #expect(LockWrapFormatCensus.inspect(service: service).state == .absent)
            #expect(makeMigrator(service: service).performPass().notApplicable == 1)
        }
        // v2Marked ↔ alreadyCurrent (fixture through the REAL production writer).
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            let v2 = try FernletLockCrypto.wrapContentKey(Self.contentKey, using: Self.wrappingKey)
            #expect(KeychainItem.store(v2, for: .wrappedContentKey, service: service) == errSecSuccess)
            #expect(LockWrapFormatCensus.inspect(service: service).state == .v2Marked)
            #expect(makeMigrator(service: service).performPass().alreadyCurrent == 1)
        }
        // legacyUnprefixed ↔ converted.
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            _ = try Self.plantLegacyRow(service: service)
            #expect(LockWrapFormatCensus.inspect(service: service).state == .legacyUnprefixed)
            #expect(makeMigrator(service: service).performPass().converted == 1)
        }
        // malformedEmpty ↔ indeterminate (census count is nil, never 0).
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            #expect(Self.plantEmptyRowOutsideTheHouseSeam(service: service) == errSecSuccess)
            let report = LockWrapFormatCensus.inspect(service: service)
            #expect(report.state == .malformedEmpty)
            #expect(report.legacyWrapCount == nil)
            #expect(makeMigrator(service: service).performPass().indeterminate == 1)
        }
        // unreadable ↔ indeterminate (both through their injected seams).
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            let unreadable: (LockKeychainKey, String) -> KeychainItem.ReadResult = { _, _ in
                .unreadable(errSecNotAvailable)
            }
            let report = LockWrapFormatCensus.inspect(service: service, loadingRow: { _, _ in
                .unreadable(errSecNotAvailable)
            })
            #expect(report.state == .unreadable(errSecNotAvailable))
            #expect(report.legacyWrapCount == nil)
            #expect(makeMigrator(service: service, loadRow: unreadable).performPass().indeterminate == 1)
        }
    }

    // T-8: the family loop — pass 1 converts, pass 2 confirms, run() reports true; a forced
    // failure reports false WITHOUT spinning (no forward progress ⇒ exactly one pass).
    @Test func runConvertsThenConfirmsAndReportsComplete() throws {
        // The success leg.
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            _ = try Self.plantLegacyRow(service: service)
            #expect(makeMigrator(service: service).run())
            let row = try #require(KeychainItem.load(for: .wrappedContentKey, service: service))
            #expect(row.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2))
        }
        // The failure leg: the staging store always fails, so the pass makes no forward progress
        // and the loop must stop after ONE pass rather than fund a second identical one.
        do {
            let service = Self.migrationService()
            defer { KeychainItem.deleteAll(service: service) }
            let legacy = try Self.plantLegacyRow(service: service)
            var storeCalls = 0
            let failingStore: (Data, LockKeychainKey, String) -> OSStatus = { _, _, _ in
                storeCalls += 1
                return errSecIO
            }
            #expect(!makeMigrator(service: service, storeRow: failingStore).run())
            #expect(storeCalls == 1, "a no-forward-progress pass must not be repeated; S3 ran \(storeCalls) times")
            #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy)
            #expect(try FernletLockCrypto.unwrapContentKey(legacy, using: Self.wrappingKey) == Self.contentKey)
        }
    }

    // MARK: - Failure injection: every injected failure point leaves the legacy row unwrapping
    // (T-9..T-13)

    // T-9: the S3 staging store fails ⇒ tally failed; the live row is byte-identical and still
    // opens via the legacy branch; nothing is staged.
    @Test func stagingWriteFailureLeavesLegacyRowByteIdentical() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)

        let failingStore: (Data, LockKeychainKey, String) -> OSStatus = { _, _, _ in errSecIO }
        let result = makeMigrator(service: service, storeRow: failingStore).performPass()
        #expect(result.failed == 1)
        #expect(!result.isClean)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy)
        #expect(try FernletLockCrypto.unwrapContentKey(legacy, using: Self.wrappingKey) == Self.contentKey)
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil)
    }

    // T-10: the S4 staged read-back returns corrupted bytes ⇒ abort before the promote; the live
    // row is untouched and the staging row is deleted.
    @Test func stagingReadBackMismatchAborts() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)

        let corruptedStagingLoad: (LockKeychainKey, String) -> KeychainItem.ReadResult = { key, svc in
            guard key == .wrappedContentKeyRewrapStaging else {
                return KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
            }
            return .found(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }
        let result = makeMigrator(service: service, loadRow: corruptedStagingLoad).performPass()
        #expect(result.failed == 1)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy,
                "a failed staged read-back must never reach the promote")
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil,
                "the staging row must be cleaned up on the abort path")
    }

    // T-11: the S5 promote returns a failing status ⇒ the live row is unchanged and opens.
    @Test func promoteFailureLeavesLegacyRowInPlace() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)

        let failingUpdate: (Data, LockKeychainKey, String) -> OSStatus = { _, _, _ in errSecIO }
        let result = makeMigrator(service: service, updateRow: failingUpdate).performPass()
        #expect(result.failed == 1)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy)
        #expect(try FernletLockCrypto.unwrapContentKey(legacy, using: Self.wrappingKey) == Self.contentKey)
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil)
    }

    // T-12: the S5 promote reports `errSecItemNotFound` ⇒ NO add is ever attempted — the
    // account's row set is unchanged (the migrator never mints custody state).
    @Test func promoteItemNotFoundNeverCreatesARow() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)
        let accountsBefore = Set(KeychainItem.loadAll(service: service).map(\.account))

        let vanishedUpdate: (Data, LockKeychainKey, String) -> OSStatus = { _, _, _ in errSecItemNotFound }
        let result = makeMigrator(service: service, updateRow: vanishedUpdate).performPass()
        #expect(result.failed == 1)
        let accountsAfter = Set(KeychainItem.loadAll(service: service).map(\.account))
        #expect(accountsAfter == accountsBefore, "an item-not-found promote must never fall back to an add")
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy)
    }

    // T-13: the S6 live read-back returns garbage ⇒ S7 restores the held old wrap; the final row
    // equals the legacy bytes and opens via the legacy branch; the restore is audited as
    // verified.
    @Test func liveReadBackMismatchRestoresTheOldWrap() throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let legacy = try Self.plantLegacyRow(service: service)

        // Live-row reads in one converting pass: S0 (1st, honest), S6 (2nd — corrupted here),
        // S7's restore re-read (3rd, honest again so the restore can verify).
        var liveRowReads = 0
        let corruptedS6Load: (LockKeychainKey, String) -> KeychainItem.ReadResult = { key, svc in
            guard key == .wrappedContentKey else {
                return KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
            }
            liveRowReads += 1
            if liveRowReads == 2 { return .found(Data([0xBA, 0xD0, 0xBA, 0xD0])) }
            return KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
        }
        let result = makeMigrator(service: service, loadRow: corruptedS6Load).performPass()
        #expect(result.failed == 1)
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == legacy,
                "S7 must restore the held legacy bytes")
        #expect(try FernletLockCrypto.unwrapContentKey(legacy, using: Self.wrappingKey) == Self.contentKey)
        #expect(audit.contains("lock.wrapRewrapRestoredLegacy", where: { $0["verified"] == "true" }))
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil)
    }

    // MARK: - The crash-window property (T-14 and its fail-after-k companion)

    // T-14, the SPY (not a failer): after EVERY keychain operation of one full converting pass,
    // a fresh REAL read of the live row must find it present and unwrapping — through either
    // branch of the real reader — to the identical content key. A process death after operation
    // k leaves exactly the state the spy observed at boundary k, so this is the per-instant
    // invariant verbatim.
    @Test func theLiveRowUnwrapsAtEveryOperationBoundary() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        _ = try Self.plantLegacyRow(service: service)

        var boundaries = 0
        var violations: [String] = []
        let checkBoundary: (String) -> Void = { label in
            boundaries += 1
            guard let row = KeychainItem.load(for: .wrappedContentKey, service: service) else {
                violations.append("after \(label): live row ABSENT")
                return
            }
            guard let opened = try? FernletLockCrypto.unwrapContentKey(row, using: Self.wrappingKey),
                  opened == Self.contentKey else {
                violations.append("after \(label): live row does not unwrap to the content key")
                return
            }
        }

        let spyingLoad: (LockKeychainKey, String) -> KeychainItem.ReadResult = { key, svc in
            let value = KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
            checkBoundary("load \(key.rawValue)")
            return value
        }
        let spyingStore: (Data, LockKeychainKey, String) -> OSStatus = { data, key, svc in
            let status = KeychainItem.store(data, for: key, service: svc)
            checkBoundary("store \(key.rawValue)")
            return status
        }
        let spyingUpdate: (Data, LockKeychainKey, String) -> OSStatus = { data, key, svc in
            let status = KeychainItem.updateReportingStatus(data, account: key.rawValue, service: svc)
            checkBoundary("update \(key.rawValue)")
            return status
        }
        let spyingDelete: (LockKeychainKey, String) -> OSStatus = { key, svc in
            let status = KeychainItem.deleteReportingStatus(account: key.rawValue, service: svc)
            checkBoundary("delete \(key.rawValue)")
            return status
        }

        let result = makeMigrator(
            service: service,
            loadRow: spyingLoad,
            storeRow: spyingStore,
            updateRow: spyingUpdate,
            deleteRow: spyingDelete
        ).performPass()
        #expect(result.converted == 1)
        #expect(violations.isEmpty, "crash-window violations: \(violations)")
        // One converting pass crosses S0 delete, S0 read, S3 store, S4 read, S5 update, S6 read,
        // S8 delete — at least 7 boundaries.
        #expect(boundaries >= 7, "expected at least the 7 recipe operations; spied \(boundaries)")
    }

    // T-14 companion: fail EVERY operation from the k-th on (the truncation loop). Stands in for
    // crashes because of the named recipe invariant — every failed operation is non-mutating on
    // the live row — so after any truncation point the row must still open through the real
    // reader (legacy branch or FLW2 branch) to the identical key.
    @Test func theLiveRowStillOpensWhenEveryOperationAfterKFails() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        // R2: one converting pass performs 7 keychain operations (S0 delete, S0 read, S3 store,
        // S4 read, S5 update, S6 read, S8 delete); the bound sweeps past the S7-path ops too.
        let maxOperationsPerPass = 10
        for k in 0...maxOperationsPerPass {
            KeychainItem.deleteAll(service: service)
            _ = try Self.plantLegacyRow(service: service)

            var opIndex = 0
            let truncatedHere: () -> Bool = {
                defer { opIndex += 1 }
                return opIndex >= k
            }
            let load: (LockKeychainKey, String) -> KeychainItem.ReadResult = { key, svc in
                truncatedHere()
                    ? .unreadable(errSecIO)
                    : KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
            }
            let store: (Data, LockKeychainKey, String) -> OSStatus = { data, key, svc in
                truncatedHere() ? errSecIO : KeychainItem.store(data, for: key, service: svc)
            }
            let update: (Data, LockKeychainKey, String) -> OSStatus = { data, key, svc in
                truncatedHere() ? errSecIO : KeychainItem.updateReportingStatus(data, account: key.rawValue, service: svc)
            }
            let delete: (LockKeychainKey, String) -> OSStatus = { key, svc in
                truncatedHere() ? errSecIO : KeychainItem.deleteReportingStatus(account: key.rawValue, service: svc)
            }

            _ = makeMigrator(
                service: service, loadRow: load, storeRow: store, updateRow: update, deleteRow: delete
            ).performPass()

            let row = KeychainItem.load(for: .wrappedContentKey, service: service)
            guard let row else {
                Issue.record("k=\(k): the live row is ABSENT — the lockout the invariant forbids")
                continue
            }
            let opened = try? FernletLockCrypto.unwrapContentKey(row, using: Self.wrappingKey)
            #expect(opened == Self.contentKey,
                    "k=\(k): the live row no longer unwraps to the content key")
        }
    }

    // T-15: a stale staging orphan beside an already-converted live row is removed by the next
    // pass's S0 hygiene, and the live row is untouched.
    @Test func stagingOrphanIsCleanedByTheNextPass() throws {
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let v2 = try FernletLockCrypto.wrapContentKey(Self.contentKey, using: Self.wrappingKey)
        #expect(KeychainItem.store(v2, for: .wrappedContentKey, service: service) == errSecSuccess)
        #expect(KeychainItem.store(Data([0xAA, 0xBB, 0xCC]), for: .wrappedContentKeyRewrapStaging,
                                   service: service) == errSecSuccess)

        let result = makeMigrator(service: service).performPass()
        #expect(result.alreadyCurrent == 1)
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil,
                "S0 must sweep the orphan staging row")
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == v2)
    }

    // T-24: the latch is DERIVED from the row's own marker (the recorded family deviation) — the
    // full truth table over all five census states — and its writes are documented no-ops that
    // change no bytes anywhere.
    @Test func rowLatchDerivesFromTheRowAndItsWritesAreNoOps() throws {
        let v2 = try FernletLockCrypto.wrapContentKey(Self.contentKey, using: Self.wrappingKey)
        let legacy = try ChaChaPoly.seal(Self.contentKey, using: SymmetricKey(data: Self.wrappingKey)).combined
        func latch(over row: KeychainItem.ReadResult) -> LockWrapRowLatch {
            LockWrapRowLatch(keychainService: "com.fernlet.lock.test.latch", loadingRow: { _, _ in row })
        }
        #expect(latch(over: .absent).isComplete, "absent = nothing to convert (all three readings)")
        #expect(latch(over: .found(v2)).isComplete)
        #expect(!latch(over: .found(legacy)).isComplete)
        #expect(!latch(over: .found(Data())).isComplete, "a corrupt slot must never read as clean")
        #expect(!latch(over: .unreadable(errSecInteractionNotAllowed)).isComplete,
                "'could not look' must never read as clean")

        // markComplete()/reset() are no-ops: over a real planted legacy row they flip no verdict
        // and change no bytes anywhere in the slot.
        let service = Self.migrationService()
        defer { KeychainItem.deleteAll(service: service) }
        let planted = try Self.plantLegacyRow(service: service)
        let realLatch = LockWrapRowLatch(keychainService: service)
        #expect(!realLatch.isComplete)
        realLatch.markComplete()
        #expect(!realLatch.isComplete, "markComplete must not manufacture completion — the row IS the latch")
        realLatch.reset()
        #expect(KeychainItem.load(for: .wrappedContentKey, service: service) == planted)
        #expect(KeychainItem.loadAll(service: service).count == 1,
                "the latch must persist nothing of its own")
    }

    // T-25 (the KeychainHelpers pin, hosted here — no KeychainHelpers suite exists): the new
    // update seam is UPDATE-ONLY, preserves attributes, and refuses empty inputs.
    @Test func updateReportingStatusIsUpdateOnly() {
        let service = "com.fernlet.lock.test.updateseam.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        let account = "com.fernlet.lock.test.updateseam.account"

        // Absent row: errSecItemNotFound comes back UN-normalized and nothing is created.
        #expect(KeychainItem.updateReportingStatus(Data([0x01]), account: account, service: service)
                == errSecItemNotFound)
        #expect(KeychainItem.loadAll(service: service).isEmpty,
                "an update against an absent row must never create one")

        // Present row: the value is replaced; accessibility and synchronizable are preserved.
        #expect(KeychainItem.store(Data([0x01]), account: account, service: service,
                                   accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly) == errSecSuccess)
        let before = Self.rowAttributes(account: account, service: service)
        #expect(KeychainItem.updateReportingStatus(Data([0x02]), account: account, service: service)
                == errSecSuccess)
        #expect(KeychainItem.load(account: account, service: service) == Data([0x02]))
        let after = Self.rowAttributes(account: account, service: service)
        #expect(after?.accessible == before?.accessible, "the update must not change the accessibility class")
        #expect(after?.synchronizable == before?.synchronizable)

        // R5: empty payload/account/service are caller bugs, refused with errSecParam.
        #expect(KeychainItem.updateReportingStatus(Data(), account: account, service: service) == errSecParam)
        #expect(KeychainItem.updateReportingStatus(Data([0x01]), account: "", service: service) == errSecParam)
        #expect(KeychainItem.updateReportingStatus(Data([0x01]), account: account, service: "") == errSecParam)
    }

    // MARK: - Service-level integration (format-faithful fake provider, real unlock seam)

    // T-16: a passcode unlock converts a planted legacy wrap and still unlocks with the
    // identical content key. SE-agnostic afterwards-phrasing is deliberate: the row is FLW2 on
    // SE-less environments, or absent where the SE hard-bind flip also ran — never
    // legacyUnprefixed.
    @Test func passcodeUnlockConvertsAPlantedLegacyWrapAndStillUnlocks() async throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        let contentKey = try await configureLockAndCaptureContentKey(service)
        _ = try await plantLegacyFakeWrap(harness, contentKey: contentKey, passcode: "123456")

        let result = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))
        let installed = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(installed == contentKey)

        let report = LockWrapFormatCensus.inspect(service: harness.serviceID)
        #expect(report.state != .legacyUnprefixed, "the row must never remain legacy after a passcode unlock")
        #expect(report.legacyWrapCount == 0)
        #expect(audit.contains("lock.wrapRewrittenFLW2"))
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) == nil)
    }

    // T-17: a failed re-wrap NEVER fails (or changes) the unlock: same result, same state, same
    // installed key; the legacy row still stands; the incompleteness is audited.
    @Test func failedRewrapNeverFailsTheUnlock() async throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        // The store seam: DROP the enclave-wrap write (report success, write nothing) so even SE
        // hardware is held in the legacy custody state — the SecureEnclaveWrapTests idiom — and
        // FAIL the staging write with a real status, which is the injected S3 failure.
        let store: (Data, LockKeychainKey, String) -> OSStatus = { data, key, svc in
            switch key {
            case .seWrappedContentKey: return errSecSuccess
            case .wrappedContentKeyRewrapStaging: return errSecIO
            default: return KeychainItem.store(data, for: key, service: svc)
            }
        }
        let service = harness.makeService(keychainStore: store)
        let contentKey = try await configureLockAndCaptureContentKey(service)
        let planted = try await plantLegacyFakeWrap(harness, contentKey: contentKey, passcode: "123456")

        let result = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))
        let installed = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(installed == contentKey, "a failed re-wrap must not perturb the installed key")
        #expect(KeychainItem.load(for: .wrappedContentKey, service: harness.serviceID) == planted,
                "the legacy wrap must be left standing for the next unlock to retry")
        #expect(audit.contains("lock.wrapFormatMigrationIncomplete"))
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) == nil)
    }

    // T-18: idempotence at the seam — the second passcode unlock converts nothing and leaves the
    // row bytes (present or absent alike) unchanged.
    @Test func secondPasscodeUnlockConvertsNothing() async throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        let contentKey = try await configureLockAndCaptureContentKey(service)
        _ = try await plantLegacyFakeWrap(harness, contentKey: contentKey, passcode: "123456")

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(audit.count(of: "lock.wrapRewrittenFLW2") == 1)
        let rowAfterFirst = KeychainItem.load(for: .wrappedContentKey, service: harness.serviceID)
        service.lock(reason: .manual)
        audit.removeAll()

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(!audit.contains("lock.wrapRewrittenFLW2"), "the second unlock must convert nothing")
        let rowAfterSecond = KeychainItem.load(for: .wrappedContentKey, service: harness.serviceID)
        #expect(rowAfterFirst == rowAfterSecond, "row bytes must be unchanged between the two unlocks")
    }

    // T-15b (§Q2a): the custody-independent sweep — an orphan staging row is removed by the next
    // passcode unlock WHATEVER that unlock's outcome and custody state, because the sweep
    // precedes the custody switch. Environment-agnostic by construction: with the live row
    // deleted, custody is hard-bound on SE environments (the unlock succeeds via the enclave
    // wrap) and undeterminable on SE-less ones (the unlock honestly throws) — the staging row is
    // gone either way.
    @Test func stagingOrphanIsSweptByTheNextPasscodeUnlockUnderAnyCustody() async throws {
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        _ = try await configureLockAndCaptureContentKey(service)
        #expect(KeychainItem.store(Data([0xAA, 0xBB]), for: .wrappedContentKeyRewrapStaging,
                                   service: harness.serviceID) == errSecSuccess)
        KeychainItem.delete(for: .wrappedContentKey, service: harness.serviceID)

        do {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
        } catch {
            // SE-less environments honestly throw on undeterminable custody — AFTER the sweep.
        }
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) == nil,
                "the custody-independent sweep must remove the orphan whatever the unlock's outcome")
    }

    // T-19: hard-bound (absent-row) and not-configured installs are untouched — no staging row
    // ever appears and neither wrap account is written.
    @Test func hardBoundAndNotConfiguredInstallsAreUntouched() async throws {
        // A fresh service with no lock: the unlock throws notConfigured and writes nothing.
        do {
            let harness = WrapMigrationServiceHarness()
            defer { harness.cleanup() }
            let service = harness.makeService()
            await #expect(throws: FernletLockError.self) {
                _ = try await service.unlock(passcode: "123456", for: .privateHub)
            }
            #expect(KeychainItem.loadAll(service: harness.serviceID).isEmpty)
        }
        // Absent-row custody: configured, then the live row deleted (already absent on SE
        // hardware, where configure() hard-binds). Neither wrap account may change and no
        // staging row may appear, whatever the unlock's outcome.
        do {
            let harness = WrapMigrationServiceHarness()
            defer { harness.cleanup() }
            let service = harness.makeService()
            _ = try await configureLockAndCaptureContentKey(service)
            KeychainItem.delete(for: .wrappedContentKey, service: harness.serviceID)
            let seWrapBefore = KeychainItem.load(for: .seWrappedContentKey, service: harness.serviceID)

            do {
                _ = try await service.unlock(passcode: "123456", for: .privateHub)
            } catch {
                // SE-less environments honestly throw on undeterminable custody.
            }
            #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) == nil)
            #expect(KeychainItem.load(for: .wrappedContentKey, service: harness.serviceID) == nil,
                    "nothing may resurrect the scrypt row on an absent-row install")
            #expect(KeychainItem.load(for: .seWrappedContentKey, service: harness.serviceID) == seWrapBefore)
        }
    }

    // T-19 extension (§Q2a): a failed S8 delete cannot strand the orphan past the next passcode
    // unlock — the unlock-tail sweep is a plain real delete that deliberately bypasses the
    // injected seam, so it bounds the orphan even while the seam keeps refusing.
    @Test func aFailedStagingDeleteCannotStrandTheOrphanPastTheNextUnlock() async throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        // The delete seam refuses staging deletes PERMANENTLY: the orphan's removal below can
        // therefore only be the unlock-tail sweep, never the migrator's own S0/S8.
        let refusingDelete: (LockKeychainKey, String) -> OSStatus = { key, svc in
            guard key != .wrappedContentKeyRewrapStaging else { return errSecIO }
            return KeychainItem.deleteReportingStatus(account: key.rawValue, service: svc)
        }
        let service = harness.makeService(keychainDelete: refusingDelete)
        let contentKey = try await configureLockAndCaptureContentKey(service)
        _ = try await plantLegacyFakeWrap(harness, contentKey: contentKey, passcode: "123456")

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(audit.contains("lock.wrapRewrittenFLW2"), "the convert itself must land")
        #expect(audit.contains("lock.wrapRewrapStagingOrphaned"), "the failed S8 must be loud")
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) != nil,
                "precondition: the refused S8 delete must actually have stranded the orphan")
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) == nil,
                "the unlock-tail sweep must bound the orphan to the next passcode unlock")
    }

    // T-20: a duress entry never reaches the migrator — the decoy leaves no residue: the row is
    // byte-identical, nothing is staged, and no migration audit line is emitted.
    @Test func duressEntryNeverRunsTheMigrator() async throws {
        let audit = WrapMigrationAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        let contentKey = try await configureLockAndCaptureContentKey(service)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        let planted = try await plantLegacyFakeWrap(harness, contentKey: contentKey, passcode: "123456")
        audit.removeAll()

        let result = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.contentKey(for: .privateHub) == nil, "the decoy is keyless")
        #expect(KeychainItem.load(for: .wrappedContentKey, service: harness.serviceID) == planted,
                "a decoy session must leave the legacy row byte-identical")
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: harness.serviceID) == nil)
        #expect(!audit.contains("lock.wrapRewrittenFLW2"))
        #expect(!audit.contains("lock.wrapFormatMigrationIncomplete"))
        #expect(!audit.contains("lock.wrapRewrapBlocked"))
    }

    // T-21: `changeCredential` still converts ORGANICALLY — the existing atomic rewrite writes a
    // fresh FLW2 wrap under the new derived key (the organic converter this design leans on).
    @Test func changeCredentialStillConvertsOrganically() async throws {
        let harness = WrapMigrationServiceHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        let contentKey = try await configureLockAndCaptureContentKey(service)
        _ = try await plantLegacyFakeWrap(harness, contentKey: contentKey, passcode: "123456")

        try await service.changeCredential(current: "123456", new: .pin6("999999"))

        let row = try #require(KeychainItem.load(for: .wrappedContentKey, service: harness.serviceID))
        #expect(row.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2),
                "the re-key must have rewritten the wrap in FLW2 form")
        let newSalt = try #require(KeychainItem.load(for: .salt, service: harness.serviceID))
        let newDerived = try await harness.crypto.deriveVerifier(
            passcode: "999999", salt: newSalt, n: FernletLockCrypto.scryptN
        )
        #expect(try harness.crypto.unwrapContentKey(row, using: newDerived) == contentKey,
                "the organic convert must wrap the SAME content key under the NEW derived key")
    }

    // MARK: - Direct-migrator plumbing

    /// Builds a direct-test migrator over REAL `FernletLockCrypto` closures and real keychain
    /// operations, with any single seam overridable for failure injection. The latch reads
    /// through the SAME load seam as S0 (the one-keychain-view-per-pass rule).
    private func makeMigrator(
        service: String,
        contentKey: Data = LockWrapFormatMigrationTests.contentKey,
        wrappingKey: Data = LockWrapFormatMigrationTests.wrappingKey,
        loadRow: ((LockKeychainKey, String) -> KeychainItem.ReadResult)? = nil,
        storeRow: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        updateRow: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        deleteRow: ((LockKeychainKey, String) -> OSStatus)? = nil
    ) -> LockWrapFormatMigrator {
        let load = loadRow ?? { key, svc in
            KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: svc)
        }
        return LockWrapFormatMigrator(
            keychainService: service,
            contentKey: contentKey,
            wrappingKey: wrappingKey,
            wrap: { try FernletLockCrypto.wrapContentKey($0, using: $1) },
            unwrap: { try FernletLockCrypto.unwrapContentKey($0, using: $1) },
            loadRow: load,
            storeRow: storeRow ?? { data, key, svc in
                KeychainItem.store(data, for: key, service: svc)
            },
            updateRow: updateRow ?? { data, key, svc in
                KeychainItem.updateReportingStatus(data, account: key.rawValue, service: svc)
            },
            deleteRow: deleteRow ?? { key, svc in
                KeychainItem.deleteReportingStatus(account: key.rawValue, service: svc)
            },
            latch: LockWrapRowLatch(keychainService: service, loadingRow: load)
        )
    }

    // MARK: - Fixtures

    /// Deterministic 32-byte stand-ins: ChaChaPoly needs no scrypt — any 32 bytes serve as the
    /// wrapping key for the direct-migrator tests. `nonisolated` so `makeMigrator`'s default
    /// arguments (evaluated in a nonisolated context) can reference them.
    private nonisolated static let wrappingKey = Data(repeating: 0x5A, count: FernletLockCrypto.keyLength)
    private nonisolated static let contentKey = Data(repeating: 0x11, count: FernletLockCrypto.keyLength)

    /// A keychain slot no other suite can collide with; every test deletes its own in a `defer`.
    private static func migrationService() -> String {
        "com.fernlet.lock.test.wrapmigration.\(UUID().uuidString)"
    }

    /// Plants the pre-`FLW2` wrap byte for byte — a bare ChaChaPoly combined box (nonce ‖ ct ‖
    /// tag) over the content key, no marker, no AAD: exactly what the legacy branch of
    /// `FernletLockCrypto.unwrapContentKey` opens. The only bare ChaChaPoly call in this change,
    /// living in TEST code as the legacy-writer stand-in (no shipping build can produce one —
    /// the fixture is the format). Returns the planted bytes.
    private static func plantLegacyRow(service: String) throws -> Data {
        let legacy = try ChaChaPoly.seal(contentKey, using: SymmetricKey(data: wrappingKey)).combined
        #expect(KeychainItem.store(legacy, for: .wrappedContentKey, service: service) == errSecSuccess)
        return legacy
    }

    /// Plants an EMPTY row via raw `SecItemAdd` — the house `KeychainItem.store` refuses empty
    /// payloads with `errSecParam` (R5), so an empty row is only reachable from outside the
    /// house seam, matching the census's provenance note.
    private static func plantEmptyRowOutsideTheHouseSeam(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.wrappedContentKey.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: Data()
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Reads back the accessibility + synchronizable attributes of one generic-password row
    /// (the `KeyCustodyBoundaryTests` idiom).
    private static func rowAttributes(
        account: String, service: String
    ) -> (accessible: String, synchronizable: Bool)? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any],
              let accessible = attrs[kSecAttrAccessible as String] as? String else { return nil }
        let synchronizable = (attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
        return (accessible, synchronizable)
    }

    // MARK: - Service-level plumbing

    /// Configures the harness's lock through the real `configure()` and returns the minted
    /// content key's bytes, leaving the service locked.
    private func configureLockAndCaptureContentKey(
        _ service: FernletLockService, passcode: String = "123456"
    ) async throws -> Data {
        try await service.configure(credential: .pin6(passcode), grantingScope: .privateHub)
        let contentKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        service.lock(reason: .manual)
        return contentKey
    }

    /// Plants an UNPREFIXED fake wrap of the given content key over the live row, registered in
    /// the fake provider's map under the wrapping key the next unlock will derive — the
    /// `legacyRawKeyVerifierUnlocksAndMigratesToDigest` fixture idiom, extended to the wrap.
    /// Returns the planted bytes.
    private func plantLegacyFakeWrap(
        _ harness: WrapMigrationServiceHarness, contentKey: Data, passcode: String
    ) async throws -> Data {
        let salt = try #require(KeychainItem.load(for: .salt, service: harness.serviceID))
        let derived = try await harness.crypto.deriveVerifier(
            passcode: passcode, salt: salt, n: FernletLockCrypto.scryptN
        )
        let legacy = harness.crypto.makeLegacyWrap(contentKey: contentKey, wrappingKey: derived)
        #expect(!legacy.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2))
        #expect(KeychainItem.store(legacy, for: .wrappedContentKey, service: harness.serviceID) == errSecSuccess)
        return legacy
    }
}

// MARK: - Harness

/// Per-test isolation for the service-level Phase 2.5 tests: UUID-scoped keychain services for
/// the lock, the sealed-content device keys and the media keys, a private narrative-buffer
/// scope, and the shared format-faithful `FakeLockCryptoProvider`. `cleanup()` also removes any
/// Secure-Enclave key a configure() may have minted for the scoped service.
@MainActor
private final class WrapMigrationServiceHarness {
    let serviceID = "com.fernlet.lock.test.wrapmigration.svc.\(UUID().uuidString)"
    let sealedContentKeyServiceID = "com.fernlet.journal.test.\(UUID().uuidString)"
    let mediaKeychainServiceID = "com.fernlet.private-media.test.\(UUID().uuidString)"
    let narrativeBufferScope = uniqueNarrativeBufferScope()
    let crypto = FakeLockCryptoProvider()

    func makeService(
        keychainStore: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        keychainUpdate: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        keychainDelete: ((LockKeychainKey, String) -> OSStatus)? = nil
    ) -> FernletLockService {
        FernletLockService(
            keychainService: serviceID,
            sealedContentKeyServices: [sealedContentKeyServiceID],
            mediaKeychainServices: [mediaKeychainServiceID],
            narrativeBufferScope: narrativeBufferScope,
            cryptoProvider: crypto,
            keychainStore: keychainStore,
            keychainUpdate: keychainUpdate,
            keychainDelete: keychainDelete
        )
    }

    func cleanup() {
        KeychainItem.deleteAll(service: serviceID)
        KeychainItem.deleteAll(service: sealedContentKeyServiceID)
        KeychainItem.deleteAll(service: mediaKeychainServiceID)
        try? PendingNarrativeBuffer(scope: narrativeBufferScope).purge()
        KeychainItem.deleteAll(service: narrativeBufferScope.keychainService)
        _ = SecureEnclaveContentKeyWrap.deleteKey(service: serviceID)
    }
}

// MARK: - Audit capture

/// Thread-safe capture of `FernletAuditLog` events for this suite (the FernletLockServiceTests
/// idiom, replicated because that copy is file-private).
private final class WrapMigrationAuditCapture {
    private let lock = NSLock()
    private var storedEvents: [(event: String, context: [String: String])] = []
    private var token: UUID?

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append((event, context))
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storedEvents.removeAll()
    }

    func contains(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.contains { $0.event == event }
    }

    func contains(_ event: String, where matchesContext: ([String: String]) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.contains { $0.event == event && matchesContext($0.context) }
    }

    func count(of event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.filter { $0.event == event }.count
    }
}
