// SealedColumnFormatMigrationTests.swift
// FernletTests
//
// Pins the Phase 2.6 sealed-column format migrator (`SealedColumnFormatMigrator`,
// Docs/Plan-Crypto-Standardization-2026-08-27.md) — the scan → convert → latch pass over the
// four sealed entities' seven ciphertext columns.
//
// Fixture discipline is the census suite's: every blob is built byte-exact from public CryptoKit
// primitives over the independently-spelled column-key derivation (pinned by the known-answer
// vector in `FernletLockCryptoTests`), never by asking the code under test to seal — except
// where a test deliberately wants the SHIPPING writer's output (the concurrent-edit pins, which
// exist to prove the editor's V3-born save wins).
//
// `.serialized` per the house sealed-store discipline: real Core Data stacks (one on-disk in a
// UUID scratch directory for the durable-progress pin), per-instance controllers, isolated
// `UserDefaults` suites for every latch, and the `DeviceBindingID.$testOverride` task-local for
// every binding — never the real keychain, never `NotificationCenter.default`.

import CoreData
import CryptoKit
import FernletDomainModel
import Foundation
import PrivateHealthStore
import PrivateMemoryStore
import Testing
import FernletFoundation
@testable import FernletCrypto
@testable import PrivateStoreCore

@Suite(.serialized)
struct SealedColumnFormatMigrationTests {

    // MARK: - Fixtures

    /// Fixed content key shared by the fixtures and the migrator's scripted vend.
    private static let contentKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    /// Install identity "A" — the install the pass runs on.
    private static let installA = Data(repeating: 0xA1, count: 16)
    /// Install identity "B" — a foreign install, for binding-mismatched fixtures.
    private static let installB = Data(repeating: 0xB2, count: 16)
    /// The at-rest marker bytes, spelled independently of the production constants (the census
    /// suite's rule: a test that sources its expectations from the code under test pins nothing).
    private static let v3Marker: UInt8 = 0x03
    private static let v2Marker: UInt8 = 0x02
    /// R2: bound on nonce redraws when hunting a first byte (P(miss) ≈ 1e-14 at 8192).
    private static let maxNonceDraws = 8192

    private enum FixtureFailure: Error {
        case couldNotDrawNonce
    }

    /// The registry purpose each sealed entity's repository seals under — sourced from the
    /// production registry (`FernletCryptoPurpose`), NOT from the migrator's own map, which is
    /// among the things under test here.
    private static func purpose(forEntity entityName: String) throws -> CryptographicPurpose {
        switch entityName {
        case "MenstrualNarrative": return FernletCryptoPurpose.KeyDerivation.menstrualNarrativeLegacyV1
        case "JournalNarrative": return FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1
        case "IntimacyLog": return FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1
        case "WorryNarrative": return FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1
        default: throw FixtureFailure.couldNotDrawNonce
        }
    }

    /// The column subkey the fixtures seal under — the characterized production derivation.
    private static func columnKey(forEntity entityName: String) throws -> SymmetricKey {
        ColumnCrypto.deriveColumnKey(
            contentKey: contentKey, purpose: try purpose(forEntity: entityName), outputByteCount: 32
        )
    }

    /// A byte-exact LEGACY blob (bare `combined`, no prefix, no AAD), redrawn until the first
    /// byte is neither marker.
    private func legacyBlob(_ plaintext: Data, entity: String) throws -> Data {
        let key = try Self.columnKey(forEntity: entity)
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(plaintext, using: key).combined
            if combined.first != Self.v3Marker && combined.first != Self.v2Marker {
                return combined
            }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A LEGACY blob whose first (nonce) byte happens to equal `marker` — the collided sliver.
    private func collidedLegacyBlob(marker: UInt8, _ plaintext: Data, entity: String) throws -> Data {
        let key = try Self.columnKey(forEntity: entity)
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(plaintext, using: key).combined
            if combined.first == marker { return combined }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A genuine V2 blob: `0x02` ‖ `combined`, binding-only AAD.
    private func v2Blob(_ plaintext: Data, entity: String, binding: Data = installA) throws -> Data {
        let key = try Self.columnKey(forEntity: entity)
        let combined = try ChaChaPoly.seal(plaintext, using: key, authenticating: binding).combined
        return Data([Self.v2Marker]) + combined
    }

    /// A genuine V3 blob: `0x03` ‖ `combined`, purpose ‖ binding AAD.
    private func v3Blob(_ plaintext: Data, entity: String, binding: Data = installA) throws -> Data {
        let key = try Self.columnKey(forEntity: entity)
        let aad = try Self.purpose(forEntity: entity).data + binding
        let combined = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad).combined
        return Data([Self.v3Marker]) + combined
    }

    /// Random unopenable bytes; `marker` prefixes them when given (the F4 fixture).
    private func garbageBlob(marker: UInt8? = nil) -> Data {
        var bytes = Data((0..<44).map { _ in UInt8.random(in: 0...255) })
        if let marker {
            bytes[bytes.startIndex] = marker
        } else if bytes.first == Self.v3Marker || bytes.first == Self.v2Marker {
            bytes[bytes.startIndex] = 0x7F
        }
        return bytes
    }

    // MARK: - Planting (census idioms, all four entities)

    private func makeController() -> PrivatePersistenceController {
        PrivatePersistenceController(inMemory: true)
    }

    private func makeLatch() throws -> SealedColumnMigrationLatch {
        let suite = try #require(UserDefaults(suiteName: "sealed-column-migration-\(UUID().uuidString)"))
        return SealedColumnMigrationLatch(defaults: suite)
    }

    /// The always-vending page key source.
    private static let alwaysKey: @Sendable () async -> SymmetricKey? = { contentKey }

    private func plantWorryRows(_ blobs: [Data?], in controller: PrivatePersistenceController) throws {
        let context = controller.container.viewContext
        try context.performAndWait {
            for blob in blobs {
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorryNarrative", into: context)
                row.setValue(UUID(), forKey: "id")
                row.setValue(Date(), forKey: "createdAt")
                row.setValue(blob, forKey: "textCiphertext")
            }
            try context.save()
        }
    }

    @discardableResult
    private func plantJournalRow(
        id: UUID = UUID(),
        dayKey: String = "2026-08-28",
        text: Data?,
        emotions: Data?,
        updatedAt: Date = Date(),
        in controller: PrivatePersistenceController
    ) throws -> UUID {
        let context = controller.container.viewContext
        try context.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "JournalNarrative", into: context)
            row.setValue(id, forKey: "id")
            row.setValue(dayKey, forKey: "dayKey")
            row.setValue("good", forKey: "tag")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "entryDate")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "createdAt")
            row.setValue(updatedAt, forKey: "updatedAt")
            row.setValue(text, forKey: "textCiphertext")
            row.setValue(emotions, forKey: "emotionsCiphertext")
            try context.save()
        }
        return id
    }

    @discardableResult
    private func plantMenstrualRow(
        note: Data?,
        flags: Data?,
        scales: Data?,
        in controller: PrivatePersistenceController
    ) throws -> UUID {
        let id = UUID()
        let context = controller.container.viewContext
        try context.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "MenstrualNarrative", into: context)
            row.setValue(id, forKey: "id")
            row.setValue(UUID().uuidString, forKey: "hkExternalUUID")
            row.setValue("2026-08-28", forKey: "dateKey")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "createdAt")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "updatedAt")
            row.setValue(note, forKey: "noteCiphertext")
            row.setValue(flags, forKey: "symptomFlagsCiphertext")
            row.setValue(scales, forKey: "customSymptomScalesCiphertext")
            try context.save()
        }
        return id
    }

    private func plantIntimacyRow(note: Data?, in controller: PrivatePersistenceController) throws {
        let context = controller.container.viewContext
        try context.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
            row.setValue(UUID(), forKey: "id")
            row.setValue("2026-08-28", forKey: "dayKey")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "eventDate")
            row.setValue(UUID().uuidString, forKey: "healthKitExternalUUID")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "createdAt")
            row.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "updatedAt")
            row.setValue(note, forKey: "noteCiphertext")
            try context.save()
        }
    }

    /// Every stored non-nil blob of one column, re-read through the store, sorted for stable
    /// comparison (the census suite's snapshot idiom).
    private func storedBlobs(entity: String, attribute: String, in controller: PrivatePersistenceController) throws -> [Data] {
        let context = controller.container.viewContext
        return try context.performAndWait {
            context.refreshAllObjects()
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
            return rows.compactMap { $0.value(forKey: attribute) as? Data }
                .sorted { $0.lexicographicallyPrecedes($1) }
        }
    }

    private func column(_ entity: String, _ attribute: String) -> SealedColumnIdentifier {
        SealedColumnIdentifier(entityName: entity, attributeName: attribute)
    }

    // MARK: - 1. The whole surface

    // MARK: THE LOAD-BEARING TEST: a corpus spanning all three rungs across all four entities /
    // seven columns migrates to proven V3, latches, and the shipping repositories still return
    // the original plaintext end-to-end.
    //
    // Deliberately run against the REAL install binding (like the repository suites), not the
    // task-local override: the repositories serialize through `viewContext.performAndWait`,
    // whose closure runs on the MAIN queue — outside this test's task, where a task-local
    // override is invisible — so a repository-interplay test must speak the binding the
    // repositories actually use.
    @Test func fullThreeRungCorpusMigratesToProvenV3() async throws {
        let binding = try #require(DeviceBindingID.current(), "the test host keychain must mint an install binding")
        let controller = makeController()
        try plantMenstrualRow(
            note: try legacyBlob(Data("cycle note".utf8), entity: "MenstrualNarrative"),
            flags: try v2Blob(Data("[]".utf8), entity: "MenstrualNarrative", binding: binding),
            scales: try v3Blob(Data("{}".utf8), entity: "MenstrualNarrative", binding: binding),
            in: controller
        )
        let journalDayKey = "2026-08-28"
        try plantJournalRow(
            dayKey: journalDayKey,
            text: try legacyBlob(Data("journal text".utf8), entity: "JournalNarrative"),
            emotions: try v2Blob(Data("[\"calm\"]".utf8), entity: "JournalNarrative", binding: binding),
            in: controller
        )
        try plantIntimacyRow(note: try legacyBlob(Data("intimacy note".utf8), entity: "IntimacyLog"), in: controller)
        try plantWorryRows([try legacyBlob(Data("worry text".utf8), entity: "WorryNarrative")], in: controller)

        let migrator = SealedColumnFormatMigrator(
            controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
        )
        let latched = await migrator.run()
        #expect(latched, "a convert pass plus a confirming pass should latch this corpus")
        #expect(migrator.latch.isComplete)

        for entity in SealedColumnFormatCensus.censusedEntities {
            for attribute in entity.ciphertextAttributeNames {
                for blob in try storedBlobs(entity: entity.entityName, attribute: attribute, in: controller) {
                    #expect(blob.first == Self.v3Marker, "\(entity.entityName).\(attribute) still holds a non-v3 blob")
                }
            }
        }

        // End-to-end through the shipping repositories: plaintext identical.
        let journalDefaults = try #require(UserDefaults(suiteName: "sealed-column-journal-\(UUID().uuidString)"))
        let journals = try JournalNarrativeRepository(controller: controller, defaults: journalDefaults)
            .narratives(forDayKey: journalDayKey, contentKey: Self.contentKey)
        #expect(journals.map(\.text) == ["journal text"])
        #expect(journals.first?.emotions == ["calm"])
        let cycleDefaults = try #require(UserDefaults(suiteName: "sealed-column-cycle-\(UUID().uuidString)"))
        let narratives = try MenstrualNarrativeRepository(controller: controller, defaults: cycleDefaults)
            .narratives(offset: 0, limit: 10, contentKey: Self.contentKey)
        #expect(narratives.map(\.note) == ["cycle note"])
    }

    // MARK: - 2. The collided sliver

    // MARK: Collided 0x03/0x02 legacy blobs are resolved BY THE KEYED OPEN — never miscounted as
    // v2 conversions or genuine v3 — and the confirming pass proves them openedV3.
    @Test func collidedLegacyBlobsAreResolvedByTheKeyedOpen() async throws {
        let controller = makeController()
        try plantWorryRows([
            try collidedLegacyBlob(marker: Self.v3Marker, Data("collided three".utf8), entity: "WorryNarrative"),
            try collidedLegacyBlob(marker: Self.v2Marker, Data("collided two".utf8), entity: "WorryNarrative")
        ], in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let first = await migrator.performPass()
            let worryText = first.columns[column("WorryNarrative", "textCiphertext")] ?? SealedColumnMigrationTally()
            #expect(worryText.convertedFromLegacyCollided == 2, "both collided blobs must resolve as LEGACY by open")
            #expect(worryText.convertedFromV2 == 0)
            #expect(worryText.openedV3 == 0)

            let census = try SealedColumnFormatCensus.run(controller: controller)
            #expect(census.tally(for: column("WorryNarrative", "textCiphertext")).v3Marked == 2)

            let second = await migrator.performPass()
            #expect(second.isClean)
            #expect(second.total.openedV3 == 2, "the confirming pass proves the converted blobs by open")
        }
    }

    // MARK: - 3/4. Byte identity and updatedAt

    // MARK: Conversion is byte-level: a deliberately non-UTF-8 plaintext survives byte-identical
    // (the openString route would have silently erased it — the exact reason the migration path
    // must never speak strings).
    @Test func plaintextIsByteIdenticalAfterConversion() async throws {
        let controller = makeController()
        let nonUTF8 = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x80, 0x01])
        #expect(String(data: nonUTF8, encoding: .utf8) == nil, "the fixture must NOT be valid UTF-8")
        try plantWorryRows([try legacyBlob(nonUTF8, entity: "WorryNarrative")], in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.convertedTotal == 1)

            let stored = try #require(try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller).first)
            #expect(stored.first == Self.v3Marker)
            let crypto = ColumnCrypto(purpose: try Self.purpose(forEntity: "WorryNarrative"))
            let reopened = try crypto.openReportingRung(stored, contentKey: Self.contentKey)
            #expect(reopened.rung == .v3)
            #expect(reopened.plaintext == nonUTF8, "conversion must preserve the plaintext byte-for-byte")
        }
    }

    // MARK: A re-seal is not an edit: `updatedAt` is untouched by conversion.
    @Test func updatedAtIsNotTouchedByConversion() async throws {
        let controller = makeController()
        let plantedUpdatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try plantJournalRow(
            text: try legacyBlob(Data("dated".utf8), entity: "JournalNarrative"),
            emotions: nil,
            updatedAt: plantedUpdatedAt,
            in: controller
        )

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.convertedTotal == 1)
        }

        let context = controller.container.viewContext
        let storedUpdatedAt: Date? = try context.performAndWait {
            context.refreshAllObjects()
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative"))
            return rows.first?.value(forKey: "updatedAt") as? Date
        }
        #expect(storedUpdatedAt == plantedUpdatedAt)
    }

    // MARK: - 5. The read-back family (the two fatal-objection fixes)

    // MARK: F10b: read-back finds DIFFERENT bytes that open under NO rung — store corruption.
    // The compare-guarded restore puts the held old blob back, the pass aborts, and remaining
    // rows are never attempted. Source-never-lost: the restored blob opens under its original rung.
    @Test func readBackCorruptionRestoresTheOldBlobAndAborts() async throws {
        let controller = makeController()
        let originalNote = try legacyBlob(Data("victim".utf8), entity: "MenstrualNarrative")
        try plantMenstrualRow(note: originalNote, flags: nil, scales: nil, in: controller)
        try plantWorryRows([
            try legacyBlob(Data("later 1".utf8), entity: "WorryNarrative"),
            try legacyBlob(Data("later 2".utf8), entity: "WorryNarrative")
        ], in: controller)

        let viewContext = controller.container.viewContext
        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let passes = PassEventLog()
            migrator.progressObserver = { passes.record($0) }
            migrator.postSavePreReadBackHookForTesting = { _ in
                viewContext.performAndWait {
                    do {
                        let rows = try viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative"))
                        rows.first?.setValue(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]), forKey: "noteCiphertext")
                        try viewContext.save()
                    } catch {
                        Issue.record("corruption hook failed: \(error)")
                    }
                }
            }
            let latched = await migrator.run()
            #expect(!latched)
            #expect(!migrator.latch.isComplete)
            #expect(passes.passResults.count == 1, "run() must NOT fund another pass after an abort")

            let result = try #require(passes.passResults.first)
            #expect(result.aborted)
            let note = result.columns[column("MenstrualNarrative", "noteCiphertext")] ?? SealedColumnMigrationTally()
            #expect(note.readBackFailed == 1)
            #expect(note.restoredOldBlob == 1)
            #expect(result.notAttempted[.aborted] == 2, "the worry rows must be counted, not silently dropped")

            let stored = try #require(try storedBlobs(entity: "MenstrualNarrative", attribute: "noteCiphertext", in: controller).first)
            #expect(stored == originalNote, "the held old bytes must be restored byte-identically")
            let crypto = ColumnCrypto(purpose: try Self.purpose(forEntity: "MenstrualNarrative"))
            let reopened = try crypto.openReportingRung(stored, contentKey: Self.contentKey)
            #expect(reopened.rung == .legacy(markerCollision: nil), "the restored blob must open under its original rung")
        }
    }

    // MARK: F10a: read-back finds bytes EQUAL to the new blob but they no longer open — the
    // environment (install binding) broke between seal and read-back. Restore + abort.
    @Test func readBackEnvironmentBreakRestoresAndAborts() async throws {
        let controller = makeController()
        let original = try legacyBlob(Data("environment".utf8), entity: "WorryNarrative")
        try plantWorryRows([original], in: controller)

        let scripted = DeviceBindingID.ScriptedBinding(.identifier(Self.installA))
        try await DeviceBindingID.$testOverride.withValue(.scripted(scripted)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            migrator.postSavePreReadBackHookForTesting = { _ in
                scripted.set(.identifier(Self.installB))
            }
            let result = await migrator.performPass()
            #expect(result.aborted)
            let tally = result.columns[column("WorryNarrative", "textCiphertext")] ?? SealedColumnMigrationTally()
            #expect(tally.readBackFailed == 1)
            #expect(tally.restoredOldBlob == 1)
            #expect(tally.converted == 0)
        }

        let stored = try #require(try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller).first)
        #expect(stored == original, "bytes-equal-unopenable must restore the held old blob")
    }

    // MARK: F10s: a concurrent legitimate edit lands in the read-back window. The editor's
    // V3-born blob WINS — no restore save ever runs — and the row tallies conflict-skipped.
    // Real install binding, deliberately: the hook's repository update seals on the MAIN queue,
    // outside this task's task-local scope (see `fullThreeRungCorpusMigratesToProvenV3`).
    @Test func concurrentEditInReadBackWindowIsNeverRestored() async throws {
        _ = try #require(DeviceBindingID.current(), "the test host keychain must mint an install binding")
        let controller = makeController()
        let journalID = UUID()
        try plantJournalRow(
            id: journalID,
            text: try legacyBlob(Data("original".utf8), entity: "JournalNarrative"),
            emotions: try legacyBlob(Data("[]".utf8), entity: "JournalNarrative"),
            in: controller
        )
        let viewContext = controller.container.viewContext
        let edited = JournalNarrative(
            id: journalID, dayKey: "2026-08-28", tag: .good,
            entryDate: Date(timeIntervalSince1970: 1_700_000_000),
            text: "edited by the user", emotions: ["calm"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date()
        )
        let hookDefaultsSuite = "sealed-column-hook-\(UUID().uuidString)"

        var migrator = SealedColumnFormatMigrator(
            controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
        )
        migrator.postSavePreReadBackHookForTesting = { _ in
            guard let defaults = UserDefaults(suiteName: hookDefaultsSuite) else { return }
            do {
                try JournalNarrativeRepository(context: viewContext, defaults: defaults)
                    .update(edited, contentKey: Self.contentKey)
            } catch {
                Issue.record("concurrent edit hook failed: \(error)")
            }
        }
        let result = await migrator.performPass()
        #expect(!result.aborted, "a superseding legitimate write must not abort the pass")
        #expect(result.total.skippedConcurrentlyModified == 2, "both superseded columns tally conflict-skipped")
        #expect(result.total.restoredOldBlob == 0, "NO restore save may run over a concurrent edit")
        #expect(result.total.readBackFailed == 0)
        #expect(!result.isClean, "conflict-skipped rows block the latch this pass")

        // The user's edit survives, end to end.
        let readDefaults = try #require(UserDefaults(suiteName: "sealed-column-read-\(UUID().uuidString)"))
        let journals = try JournalNarrativeRepository(controller: controller, defaults: readDefaults)
            .narratives(forDayKey: "2026-08-28", contentKey: Self.contentKey)
        #expect(journals.map(\.text) == ["edited by the user"])
    }

    // MARK: F10d: a row DELETED in the read-back window is indeterminate — a deliberate deletion
    // is never restored, and no restore-failure audit fires for it.
    @Test func rowDeletedInReadBackWindowIsIndeterminateNotRestored() async throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob(Data("doomed".utf8), entity: "WorryNarrative")], in: controller)
        let viewContext = controller.container.viewContext
        let audit = AuditEventLog()
        let token = FernletAuditLog.addCaptureHandler { event, _ in audit.record(event) }
        defer { FernletAuditLog.removeCaptureHandler(token) }

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            migrator.postSavePreReadBackHookForTesting = { _ in
                viewContext.performAndWait {
                    do {
                        let rows = try viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative"))
                        rows.forEach(viewContext.delete)
                        try viewContext.save()
                    } catch {
                        Issue.record("delete hook failed: \(error)")
                    }
                }
            }
            let result = await migrator.performPass()
            #expect(!result.aborted, "a mid-window deletion is benign — the pass continues")
            #expect(result.total.indeterminate == 1)
            #expect(result.total.readBackFailed == 0)
            #expect(result.total.restoredOldBlob == 0, "a deleted row must never be restored")
        }

        let survivors = try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller)
        #expect(survivors.isEmpty, "the restore ledger must not resurrect the deleted row")
        #expect(!audit.events.contains("sealedColumn.readBackFailedRestored"))
        #expect(!audit.events.contains("sealedColumn.readBackFailedRestoreFailed"))
    }

    // MARK: F11: the compensating restore's save fails twice (one bounded retry) — exactly two
    // attempts, a loud audit line, `restoreFailed`, and an abort. The forfeit is never silent.
    @Test func restoreSaveRetriesOnceThenForfeitsLoudly() async throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob(Data("forfeit".utf8), entity: "WorryNarrative")], in: controller)
        let viewContext = controller.container.viewContext
        let audit = AuditEventLog()
        let token = FernletAuditLog.addCaptureHandler { event, _ in audit.record(event) }
        defer { FernletAuditLog.removeCaptureHandler(token) }
        let attempts = HookCounter()
        struct InjectedSaveFailure: Error {}

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            migrator.postSavePreReadBackHookForTesting = { _ in
                viewContext.performAndWait {
                    do {
                        let rows = try viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative"))
                        rows.first?.setValue(Data([0x00, 0x01, 0x02]), forKey: "textCiphertext")
                        try viewContext.save()
                    } catch {
                        Issue.record("corruption hook failed: \(error)")
                    }
                }
            }
            migrator.restoreSaveOverrideForTesting = { _ in
                _ = attempts.next()
                throw InjectedSaveFailure()
            }
            let result = await migrator.performPass()
            #expect(attempts.value == 2, "the restore save is attempted exactly twice — one bounded retry")
            #expect(result.aborted)
            #expect(result.total.restoreFailed == 1)
            #expect(result.total.readBackFailed == 1)
            #expect(result.total.restoredOldBlob == 0)
        }
        #expect(audit.events.contains("sealedColumn.readBackFailedRestoreFailed"))
    }

    // MARK: - 6. Re-lock mid-pass

    // MARK: F12: the key source vends for page 1 of a 120-row corpus then answers nil. Exactly
    // the first page's conversions persist durably (proven via a FRESH controller over the same
    // on-disk store), the rest are notAttempted(keyRevoked), the latch stays closed — and a
    // later run with a full key source completes and latches.
    @Test func reLockMidPassStopsFailClosedWithDurableProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-column-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let controller = PrivatePersistenceController(storeURL: storeURL)
        let totalRows = 120
        let pageSize = SealedColumnFormatMigrator.defaultPageSize
        let blobs: [Data?] = try (0..<totalRows).map { index -> Data? in
            try legacyBlob(Data("row \(index)".utf8), entity: "WorryNarrative")
        }
        try plantWorryRows(blobs, in: controller)

        let vend = HookCounter()
        let onePageKey: @Sendable () async -> SymmetricKey? = {
            vend.next() == 1 ? Self.contentKey : nil
        }
        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: onePageKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.rowsScanned == pageSize)
            #expect(result.convertedTotal == pageSize)
            #expect(result.notAttempted[.keyRevoked] == totalRows - pageSize)
            #expect(!result.aborted)
            #expect(result.stoppedOnlyByKeyRevocation)
            #expect(result.madeForwardProgress, "F12 deliberately keeps its progress flag")
            #expect(!migrator.latch.isComplete)
        }

        // Durability, through a FRESH controller over the same file.
        let fresh = PrivatePersistenceController(storeURL: storeURL)
        let storedAfterStop = try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: fresh)
        #expect(storedAfterStop.filter { $0.first == Self.v3Marker }.count == pageSize)
        #expect(storedAfterStop.filter { $0.first != Self.v3Marker }.count == totalRows - pageSize)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: fresh, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let latched = await migrator.run()
            #expect(latched, "a later unlock's run over the same store completes and latches")
        }
        let storedAfterFinish = try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: fresh)
        #expect(storedAfterFinish.allSatisfy { $0.first == Self.v3Marker })
    }

    // MARK: - 7. Binding failures

    // MARK: F14: no install binding at preflight aborts WITHOUT writing — never a re-seal to
    // "what the writer would write today" (a legacy-to-legacy churn the census could not see).
    @Test func bindingUnavailableAbortsWithoutWriting() async throws {
        let controller = makeController()
        try plantWorryRows([
            try legacyBlob(Data("untouched 1".utf8), entity: "WorryNarrative"),
            try legacyBlob(Data("untouched 2".utf8), entity: "WorryNarrative")
        ], in: controller)
        let before = try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller)

        try await DeviceBindingID.$testOverride.withValue(.unavailable) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.abortedNoBinding)
            #expect(result.notAttempted[.noBinding] == 2)
            #expect(result.rowsScanned == 0)
            #expect(!result.madeForwardProgress)
            #expect(!result.isClean)
        }
        #expect(try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller) == before)
    }

    // MARK: F5: a transient binding READ ERROR over marked rows is indeterminate-retryable —
    // never counted unopenable, never converted, never aborting.
    @Test func bindingReadErrorIsIndeterminateNotUnopenable() async throws {
        let controller = makeController()
        try plantWorryRows([
            try v3Blob(Data("genuine three".utf8), entity: "WorryNarrative"),
            try v2Blob(Data("genuine two".utf8), entity: "WorryNarrative")
        ], in: controller)

        let scripted = DeviceBindingID.ScriptedBinding(.identifier(Self.installA))
        // The vend flips the binding to a read error AFTER preflight (which needs `current()`),
        // so the page's opens hit the outage.
        let flippingKey: @Sendable () async -> SymmetricKey? = {
            scripted.set(.readError)
            return Self.contentKey
        }
        try await DeviceBindingID.$testOverride.withValue(.scripted(scripted)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: flippingKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.total.bindingReadError == 2)
            #expect(result.total.unopenableMarked == 0, "a keychain outage must never read as corruption")
            #expect(result.total.converted == 0)
            #expect(!result.aborted)
            #expect(!result.isClean, "the retryable outage still blocks the latch")
        }
    }

    // MARK: - 8/9. Idempotence and unopenable buckets

    // MARK: A second pass over a converted corpus is a byte-identical no-op that reads clean.
    @Test func secondPassIsAByteIdenticalNoOp() async throws {
        let controller = makeController()
        try plantWorryRows([
            try legacyBlob(Data("one".utf8), entity: "WorryNarrative"),
            try v2Blob(Data("two".utf8), entity: "WorryNarrative"),
            try legacyBlob(Data("three".utf8), entity: "WorryNarrative")
        ], in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let first = await migrator.performPass()
            #expect(first.convertedTotal == 3)
            let snapshot = try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller)

            let second = await migrator.performPass()
            #expect(second.isClean)
            #expect(second.convertedTotal == 0)
            #expect(second.total.openedV3 == 3)
            #expect(try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller) == snapshot)
        }
    }

    // MARK: F3/F4: unopenable blobs block the latch in SPLIT buckets — unprefixed garbage is the
    // census-visible legacy residue; marked garbage and binding-mismatched V3 are the named
    // marked-residue class. Bytes untouched on every path.
    @Test func unopenableBlobsBlockTheLatchInSplitBuckets() async throws {
        let controller = makeController()
        try plantWorryRows([
            garbageBlob(),
            garbageBlob(marker: Self.v3Marker),
            try v3Blob(Data("foreign install".utf8), entity: "WorryNarrative", binding: Self.installB)
        ], in: controller)
        let before = try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let latched = await migrator.run()
            #expect(!latched)
            #expect(!migrator.latch.isComplete)
            let result = await migrator.performPass()
            #expect(result.total.unopenableUnprefixed == 1)
            #expect(result.total.unopenableMarked == 2)
        }
        #expect(try storedBlobs(entity: "WorryNarrative", attribute: "textCiphertext", in: controller) == before)
    }

    // MARK: - 10. Optimistic-locking conflicts

    // MARK: F8: an edit landing between a row's fault and the page save conflicts the save; the
    // page rolls back, the rows tally conflict-skipped, and the USER's edit survives end to end.
    @Test func concurrentEditWinsAndTheMigratorSkips() async throws {
        let controller = makeController()
        let editedID = UUID()
        try plantJournalRow(id: editedID, text: try legacyBlob(Data("stale".utf8), entity: "JournalNarrative"), emotions: nil, in: controller)
        try plantJournalRow(text: try legacyBlob(Data("bystander".utf8), entity: "JournalNarrative"), emotions: nil, in: controller)
        let viewContext = controller.container.viewContext
        let edited = JournalNarrative(
            id: editedID, dayKey: "2026-08-28", tag: .good,
            entryDate: Date(timeIntervalSince1970: 1_700_000_000),
            text: "fresh user edit", emotions: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date()
        )
        let hookDefaultsSuite = "sealed-column-hook-\(UUID().uuidString)"

        // Real install binding, same reason as the read-back sibling above.
        _ = try #require(DeviceBindingID.current(), "the test host keychain must mint an install binding")
        var migrator = SealedColumnFormatMigrator(
            controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
        )
        migrator.prePageSaveHookForTesting = { _ in
            guard let defaults = UserDefaults(suiteName: hookDefaultsSuite) else { return }
            do {
                try JournalNarrativeRepository(context: viewContext, defaults: defaults)
                    .update(edited, contentKey: Self.contentKey)
            } catch {
                Issue.record("conflict hook failed: \(error)")
            }
        }
        let result = await migrator.performPass()
        #expect(result.total.skippedConcurrentlyModified >= 1, "the conflicting page must be skipped, not clobbered")
        #expect(result.total.converted == 0, "the whole page rolled back")
        #expect(!result.aborted)
        #expect(!result.isClean, "conflict-skipped rows block the latch this pass")

        let readDefaults = try #require(UserDefaults(suiteName: "sealed-column-read-\(UUID().uuidString)"))
        let texts = try JournalNarrativeRepository(controller: controller, defaults: readDefaults)
            .narratives(forDayKey: "2026-08-28", contentKey: Self.contentKey)
            .map(\.text)
            .sorted()
        #expect(texts.contains("fresh user edit"), "the user's edit must survive")
    }

    // MARK: F8's other half: conflict-skipped rows are UNPROVEN, NOT HEALED. After a
    // single-column concurrent edit conflicts the page, the follow-up pass tallies a CONVERSION
    // — not openedV3 — for the columns the editor never touched.
    @Test func conflictSkippedRowsAreUnprovenNotHealed() async throws {
        let controller = makeController()
        try plantMenstrualRow(
            note: try legacyBlob(Data("note".utf8), entity: "MenstrualNarrative"),
            flags: try legacyBlob(Data("[]".utf8), entity: "MenstrualNarrative"),
            scales: try legacyBlob(Data("{}".utf8), entity: "MenstrualNarrative"),
            in: controller
        )
        let viewContext = controller.container.viewContext
        let editorBlob = try v3Blob(Data("edited note".utf8), entity: "MenstrualNarrative")

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            migrator.prePageSaveHookForTesting = { _ in
                viewContext.performAndWait {
                    do {
                        let rows = try viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative"))
                        rows.first?.setValue(editorBlob, forKey: "noteCiphertext")
                        try viewContext.save()
                    } catch {
                        Issue.record("single-column edit hook failed: \(error)")
                    }
                }
            }
            let first = await migrator.performPass()
            #expect(first.total.skippedConcurrentlyModified == 3, "the whole page's staged conversions roll back")
            #expect(first.total.converted == 0)

            var followUp = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            followUp.prePageSaveHookForTesting = nil
            let second = await followUp.performPass()
            let noteTally = second.columns[column("MenstrualNarrative", "noteCiphertext")] ?? SealedColumnMigrationTally()
            let flagsTally = second.columns[column("MenstrualNarrative", "symptomFlagsCiphertext")] ?? SealedColumnMigrationTally()
            let scalesTally = second.columns[column("MenstrualNarrative", "customSymptomScalesCiphertext")] ?? SealedColumnMigrationTally()
            #expect(noteTally.openedV3 == 1, "the editor's column is genuinely V3")
            #expect(flagsTally.convertedFromLegacyUnprefixed == 1, "the untouched column was NOT healed by the conflict")
            #expect(scalesTally.convertedFromLegacyUnprefixed == 1)
        }
    }

    // MARK: - 11. Latch revalidation (§9)

    // MARK: A set latch is not believed: marker-visible legacy resets it; a clean keyless census
    // confirms it. Keyless by construction — `revalidate` has no key-source parameter, so the
    // content key structurally cannot be requested.
    @Test func latchRevalidationResetsOnMarkerVisibleLegacy() async throws {
        let dirtyController = makeController()
        try plantWorryRows([try legacyBlob(Data("survivor".utf8), entity: "WorryNarrative")], in: dirtyController)
        let dirtyLatch = try makeLatch()
        dirtyLatch.markComplete()
        #expect(SealedColumnFormatMigrator.revalidate(controller: dirtyController, latch: dirtyLatch) == .reset)
        #expect(!dirtyLatch.isComplete, "marker-visible legacy must clear a stale latch")

        let cleanController = makeController()
        try plantWorryRows([try v3Blob(Data("current".utf8), entity: "WorryNarrative")], in: cleanController)
        let cleanLatch = try makeLatch()
        cleanLatch.markComplete()
        #expect(SealedColumnFormatMigrator.revalidate(controller: cleanController, latch: cleanLatch) == .confirmed)
        #expect(cleanLatch.isComplete)
    }

    // MARK: A census throw is NEITHER confirmation NOR a reset: the latch is kept unconfirmed,
    // and the audit line lands so the skipped recheck is never silent.
    @Test func revalidationCensusThrowLeavesLatchUnconfirmedAndRetries() async throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob(Data("hidden".utf8), entity: "WorryNarrative")], in: controller)
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        let latch = try makeLatch()
        latch.markComplete()
        let audit = AuditEventLog()
        let token = FernletAuditLog.addCaptureHandler { event, _ in audit.record(event) }
        defer { FernletAuditLog.removeCaptureHandler(token) }

        #expect(SealedColumnFormatMigrator.revalidate(controller: controller, latch: latch) == .unavailable)
        #expect(latch.isComplete, "a store outage must not burn the latch")
        #expect(audit.events.contains("sealedColumn.latchRevalidationUnavailable"))
    }

    // MARK: The exception: `tableDoesNotMatchModel` RESETS — the latch's subject definition
    // drifted under it (the same reason the pass's own preflight aborts on that check).
    @Test func revalidationTableDriftResetsLatch() async throws {
        let latch = try makeLatch()
        latch.markComplete()
        let outcome = SealedColumnFormatMigrator.revalidate(latch: latch) {
            throw SealedColumnFormatCensus.Failure.tableDoesNotMatchModel(missing: [], unlisted: [])
        }
        #expect(outcome == .reset)
        #expect(!latch.isComplete)
    }

    // MARK: - 12/13. Bounds and empties

    // MARK: F13: exhausting the row budget truncates LOUDLY and blocks the latch — a truncated
    // pass counted a subset, so its claim covers nothing beyond it (census rule).
    @Test func rowBudgetTruncationBlocksTheLatch() async throws {
        let controller = makeController()
        let blobs: [Data?] = try (0..<5).map { index -> Data? in
            try legacyBlob(Data("budget \(index)".utf8), entity: "WorryNarrative")
        }
        try plantWorryRows(blobs, in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch(), rowBudget: 2
            )
            let result = await migrator.performPass()
            #expect(result.truncated)
            #expect(result.notAttempted[.rowBudget] == 3)
            #expect(result.convertedTotal == 2)
            #expect(!result.isClean)

            let latched = await migrator.run()
            #expect(!latched)
            #expect(!migrator.latch.isComplete)
        }
    }

    // MARK: F2: empty and nil columns skip — never converted, never blocking — so a corpus of
    // empties latches clean.
    @Test func emptyAndNilColumnsSkipNotConvert() async throws {
        let controller = makeController()
        try plantJournalRow(text: nil, emotions: nil, in: controller)
        try plantJournalRow(text: nil, emotions: nil, in: controller)
        try plantWorryRows([Data()], in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.isClean)
            #expect(result.total.skippedEmpty == 5)
            #expect(result.convertedTotal == 0)
            let latched = await migrator.run()
            #expect(latched)
        }
    }

    // MARK: - 14/15. Cross-checks

    // MARK: Counter and converter agree: after a clean latching run, the keyless census reads
    // zero definite legacy and zero v2 — the gate numbers.
    @Test func censusAgreementAfterCleanPass() async throws {
        let controller = makeController()
        try plantWorryRows([
            try legacyBlob(Data("a".utf8), entity: "WorryNarrative"),
            try v2Blob(Data("b".utf8), entity: "WorryNarrative")
        ], in: controller)
        try plantIntimacyRow(note: try legacyBlob(Data("c".utf8), entity: "IntimacyLog"), in: controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let latched = await migrator.run()
            #expect(latched)
        }
        let census = try SealedColumnFormatCensus.run(controller: controller)
        #expect(census.definitelyLegacy == 0)
        #expect(census.total.v2Marked == 0)
    }

    // MARK: F15: a store that is not attached aborts indeterminate — never counted, never
    // converted, never latched (the census's double-guard behavior mirrored).
    @Test func storeUnavailableAbortsIndeterminate() async throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob(Data("orphan".utf8), entity: "WorryNarrative")], in: controller)
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            let migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            let result = await migrator.performPass()
            #expect(result.aborted)
            #expect(result.rowsScanned == 0)
            #expect(!result.madeForwardProgress)
            let latched = await migrator.run()
            #expect(!latched)
        }
    }

    // MARK: - 18/19. Wipes and abort re-funding

    // MARK: F16: a delete-all purge + rebuild landing between a page's save and its read-back
    // aborts the pass indeterminate, attempts NO restore, and the rebuilt store stays EMPTY —
    // nothing from the restore ledger or the pending page can resurrect wiped rows.
    @Test func deleteAllMidPassNeverResurrectsRows() async throws {
        let controller = makeController()
        try plantWorryRows([
            try legacyBlob(Data("wiped 1".utf8), entity: "WorryNarrative"),
            try legacyBlob(Data("wiped 2".utf8), entity: "WorryNarrative")
        ], in: controller)
        let box = ControllerBox(controller)

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch()
            )
            migrator.postSavePreReadBackHookForTesting = { _ in
                do {
                    try box.controller.purgeEncryptedEntities()
                    try box.controller.rebuildStore()
                } catch {
                    Issue.record("mid-pass wipe hook failed: \(error)")
                }
            }
            let result = await migrator.performPass()
            #expect(result.aborted, "a store torn off (and rebuilt) under the pass must abort it")
            #expect(result.total.indeterminate == 2, "purged rows classify indeterminate at read-back (F10d)")
            #expect(result.total.restoredOldBlob == 0, "NO restore save may be attempted for a purged row")
            #expect(result.total.restoreFailed == 0)
            #expect(!result.madeForwardProgress)
        }

        let context = controller.container.viewContext
        let survivors: Int = try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative"))
        }
        #expect(survivors == 0, "the rebuilt store must stay empty — the wipe is final")
    }

    // MARK: The `madeForwardProgress && !aborted` clause: a pass that converted a page and THEN
    // aborted is not re-funded — `run()` performs exactly one pass, and the latch stays closed.
    @Test func abortedPassIsNotReFundedByRun() async throws {
        let controller = makeController()
        try plantWorryRows([
            try legacyBlob(Data("clean page".utf8), entity: "WorryNarrative"),
            try legacyBlob(Data("corrupted page".utf8), entity: "WorryNarrative")
        ], in: controller)
        let viewContext = controller.container.viewContext
        let pageCommits = HookCounter()

        try await DeviceBindingID.$testOverride.withValue(.identifier(Self.installA)) {
            var migrator = SealedColumnFormatMigrator(
                controller: controller, keySource: Self.alwaysKey, latch: try makeLatch(), pageSize: 1
            )
            let passes = PassEventLog()
            migrator.progressObserver = { passes.record($0) }
            migrator.postSavePreReadBackHookForTesting = { _ in
                guard pageCommits.next() == 2 else { return }
                viewContext.performAndWait {
                    do {
                        let request = NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative")
                        let rows = try viewContext.fetch(request)
                        // Corrupt the row page 2 just committed (the one now holding a v3 blob
                        // that is NOT the page-1 row already verified).
                        let marked = rows.filter { ($0.value(forKey: "textCiphertext") as? Data)?.first == 0x03 }
                        marked.last?.setValue(Data([0x0B, 0xAD]), forKey: "textCiphertext")
                        try viewContext.save()
                    } catch {
                        Issue.record("page-2 corruption hook failed: \(error)")
                    }
                }
            }
            let latched = await migrator.run()
            #expect(!latched)
            #expect(!migrator.latch.isComplete)
            #expect(passes.passResults.count == 1, "run() must perform exactly ONE pass after an abort")
            let result = try #require(passes.passResults.first)
            #expect(result.aborted)
            #expect(result.convertedTotal >= 1, "page 1's conversion verified — the clause, not zero progress, stops the loop")
            #expect(!result.madeForwardProgress, "aborted forces madeForwardProgress false")
        }
    }
}

// MARK: - Test plumbing

/// Fire-once / counting box for `@Sendable` hook closures. `@unchecked Sendable` on the
/// documented invariant: the one mutable field is only ever touched under `lock`.
private nonisolated final class HookCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new count.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    /// The current count.
    var value: Int {
        lock.withLock { count }
    }
}

/// Collects the migrator's progress events off the `@Sendable` observer. Same `@unchecked
/// Sendable` invariant as `HookCounter`.
private nonisolated final class PassEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SealedColumnMigrationProgressEvent] = []

    /// Records one event.
    func record(_ event: SealedColumnMigrationProgressEvent) {
        lock.withLock { events.append(event) }
    }

    /// Every `passEnded` result, in completion order.
    var passResults: [SealedColumnMigrationResult] {
        lock.withLock {
            events.compactMap { event in
                if case .passEnded(let result) = event { return result }
                return nil
            }
        }
    }
}

/// Collects audit event names off `FernletAuditLog`'s capture seam. Same invariant.
private nonisolated final class AuditEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    /// Records one event name.
    func record(_ event: String) {
        lock.withLock { stored.append(event) }
    }

    /// Every recorded event name.
    var events: [String] {
        lock.withLock { stored }
    }
}

/// Lets a `@Sendable` test hook reach the (non-Sendable) controller it is deliberately tearing
/// down mid-pass. `@unchecked Sendable` is safe here because the F16 test's hook runs strictly
/// inside the migrator's own page closure — one access at a time by construction.
private nonisolated final class ControllerBox: @unchecked Sendable {
    let controller: PrivatePersistenceController

    init(_ controller: PrivatePersistenceController) {
        self.controller = controller
    }
}
