// CryptoFormatCensusTests.swift
// FernletTests
//
// The aggregate half of Phase 0 (Docs/Plan-Crypto-Standardization-2026-08-27.md). The five
// per-surface censuses have their own suites, each proving that surface counts planted bytes; this
// file proves the thing NONE of them can: that `CryptoFormatCensus` — the app-side aggregator the
// DEBUG diagnostic renders — carries each of those numbers into the right row, and that the rows
// which have no number say so instead of showing a zero.
//
// Two failure modes are worth stating, because they are what the assertions below are shaped
// around:
//   1. A mapping that drops a surface, or wires surface A's number into surface B's row, produces a
//      confident, wrong census. Every per-surface suite would still be green.
//   2. A row model that renders a missing count as `0` hands Phase 3 — which DELETES legacy
//      readers — the clean reading it is gated on. Every `nil` in the per-surface APIs
//      (`legacyCount`, `legacyWrapCount`) exists to prevent exactly that, and an aggregator is
//      precisely where such a `nil` gets quietly coalesced.

import CoreData
import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
import FernletLock
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit
@testable import Fernlet

/// Pins ``CryptoFormatCensus``: the five-surface fold, the sixth (uncountable) row, and the
/// never-render-nil-as-zero invariant.
///
/// `.serialized` per the house sealed-store discipline — the end-to-end test builds a real (if
/// in-memory) `PrivatePersistenceController` alongside real temp directories and a real keychain
/// slot, and the shared-disk-root flake family is well documented. Every fixture is unique per test
/// (a UUID directory, a UUID keychain service, a fresh controller) and cleaned up in a `defer`; no
/// test here goes anywhere near `FernletStore`, whose construction carries its own isolation wall
/// (`PhotoDirectoryIsolationTests`) — which is why the aggregator takes injected
/// ``CryptoFormatCensus/Inputs`` rather than a store.
///
/// Deliberately NOT wrapped in `#if DEBUG`, even though `CryptoFormatCensus` itself is. The scheme
/// pins the test action to the Debug configuration (`Fernlet.xcscheme`, `TestAction
/// buildConfiguration = "Debug"`), which defines `DEBUG` for both the app target and this bundle,
/// so the symbols are always there for `@testable import Fernlet`. Guarding the suite would trade a
/// compile error nobody can miss for a suite that silently evaporates in a configuration where its
/// subject does not exist — and a census suite that can vanish quietly is the exact failure mode
/// every assertion below is written against.
@Suite(.serialized)
struct CryptoFormatCensusTests {

    // MARK: - Fixtures

    /// Fixed key for every fixture blob. Nothing in any census decrypts, so its only job is to make
    /// CryptoKit emit real, well-formed sealed boxes.
    private static let fixtureKey = SymmetricKey(data: Data(repeating: 0x2B, count: 32))

    /// Bound on nonce redraws when a fixture must avoid a marker byte. A ChaChaPoly nonce is
    /// uniform, so `(255/256)^8192 ≈ 1e-14` — the budget the sibling census suites use (R2: the
    /// redraw loop is bounded rather than "until it works").
    private static let maxNonceDraws = 8192

    private enum FixtureFailure: Error {
        /// 8192 uniform draws all hit the marker byte: the RNG is broken, not the test.
        case couldNotDrawNonce
    }

    /// A byte-exact `ColumnCrypto` LEGACY blob: a bare ChaChaPoly `combined` value with no version
    /// prefix, redrawn until its first byte is neither `0x03` (v3) nor `0x02` (v2) so it lands
    /// unambiguously in the definitely-legacy bucket. Markers spelled independently of the
    /// production constants: these are at-rest format bytes, and a test that sourced them from the
    /// code under test would agree with any change to that code, including a wrong one.
    private func legacyColumnBlob() throws -> Data {
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(Data("sealed before binding".utf8), using: Self.fixtureKey).combined
            if combined.first != 0x03 && combined.first != 0x02 { return combined }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A byte-exact `PendingNarrativeBuffer` LEGACY file: a bare ChaChaPoly box with no `FNB2`
    /// prefix, redrawn until its first four bytes are not the marker.
    private func legacyNarrativeBytes() throws -> Data {
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(Data("[]".utf8), using: Self.fixtureKey).combined
            if !combined.starts(with: Data("FNB2".utf8)) { return combined }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A byte-exact `FernletLockCrypto` LEGACY wrap: a bare ChaChaPoly box over a stand-in content
    /// key, no `FLW2` marker and no additional authenticated data.
    private func legacyLockWrapBytes() throws -> Data {
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(Data(repeating: 0x11, count: 32), using: Self.fixtureKey).combined
            if !combined.starts(with: Data("FLW2".utf8)) { return combined }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A byte-exact `MediaAtRestCrypto` LEGACY blob: an AES-GCM combined box with no `FMA2` prefix,
    /// which is what the pre-domain-separation writer put on disk.
    private func legacyMediaBytes() throws -> Data {
        let combined = try #require(try AES.GCM.seal(Data("photo".utf8), using: Self.fixtureKey).combined)
        #expect(!combined.starts(with: Data("FMA2".utf8)), "the legacy media fixture must not carry the marker")
        return combined
    }

    /// A byte-exact `FSC1` heart-drop sidecar: the legacy magic followed by a box sealed with NO
    /// authenticated data — the shape that had to become a read-only rung.
    private func legacyHeartDropBytes() throws -> Data {
        // cryptographic-domain: legacy-read — reproduces the pre-91c3956 unbound sidecar on purpose.
        let box = try ChaChaPoly.seal(Data("{}".utf8), using: Self.fixtureKey)
        return Data("FSC1".utf8) + box.combined
    }

    // MARK: - Planting

    /// Inserts one `WorryNarrative` row per blob — the simplest sealed entity (exactly one
    /// ciphertext column), so a row count and a classification count are the same number.
    private func plantWorryRows(_ blobs: [Data], in controller: PrivatePersistenceController) throws {
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

    /// A unique own-photo root with the three sealed corpora created, so a planted file lands where
    /// the production layout says it lives.
    private func makeOwnPhotoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.cryptoCensus.own.\(UUID().uuidString)", isDirectory: true)
        for directory in OwnPhotoCorpusLayout.sealedLocations(in: root).directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    /// A unique directory, created on disk — used for the friend-wall root and the heart-drop root,
    /// which are separate roots in production and separate here too.
    private func makeDirectory(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.cryptoCensus.\(label).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A keychain slot no other suite can collide with; `.test.` matches the convention
    /// `PrivacyWipeCoverageTests` skips, so a per-test service never reads as a new app service.
    private func uniqueLockService() -> String {
        "com.fernlet.lock.test.census.\(UUID().uuidString)"
    }

    // MARK: - The end-to-end proof

    /// One planted legacy blob per countable surface, censused through the real aggregator: every
    /// surface's row reports **its own** planted count.
    ///
    /// This is the "the census counts something" proof at the aggregate level. Each surface gets
    /// exactly one legacy blob and nothing else, so a mapping that crossed two surfaces' numbers
    /// would still produce 1s — which is why the row's `surface`, its detail line and its status are
    /// asserted alongside the count, and why the media row (whose bucket also absorbs unrecognised
    /// bytes) is checked for the *absence* of blind spots.
    @Test func everySurfaceReportsItsOwnPlantedLegacyBlob() async throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let ownRoot = try makeOwnPhotoRoot()
        let wallRoot = try makeDirectory("wall")
        let heartDropRoot = try makeDirectory("heartdrop")
        let narrativeScope = uniqueNarrativeBufferScope()
        let lockService = uniqueLockService()
        defer {
            for root in [ownRoot, wallRoot, heartDropRoot, narrativeScope.directory] {
                try? FileManager.default.removeItem(at: root)
            }
            KeychainItem.deleteAll(service: lockService)
            KeychainItem.deleteAll(service: narrativeScope.keychainService)
        }

        try plantWorryRows([try legacyColumnBlob()], in: controller)
        try legacyMediaBytes().write(
            to: OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot).appendingPathComponent("\(UUID().uuidString).jpg"),
            options: .atomic
        )
        try FileManager.default.createDirectory(at: narrativeScope.directory, withIntermediateDirectories: true)
        try legacyNarrativeBytes().write(to: PendingNarrativeBuffer.fileURL(in: narrativeScope.directory), options: .atomic)
        let plantedWrap = try legacyLockWrapBytes()
        let wrapStatus = KeychainItem.store(
            plantedWrap,
            account: LockWrapFormatCensus.account,
            service: lockService,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        #expect(wrapStatus == errSecSuccess, "the fixture wrap was not filed in the keychain")
        try legacyHeartDropBytes().write(
            to: HeartDropSidecarFormatCensus.Sidecar.outbox.url(in: heartDropRoot),
            options: .atomic
        )

        let report = await CryptoFormatCensus.run(inputs: CryptoFormatCensus.Inputs(
            sealedStore: controller,
            ownPhotoDocumentsDirectory: ownRoot,
            friendWallSupportDirectory: wallRoot,
            narrativeScope: narrativeScope,
            lockKeychainService: lockService,
            heartDropDirectory: heartDropRoot
        ))

        #expect(report.allSurfacesReported, "the plan's exit criterion is a row for every one of the six surfaces")
        #expect(report.rows.map(\.surface) == CryptoFormatCensusSurface.allCases)
        for surface in [CryptoFormatCensusSurface.sealedColumns, .pendingNarrativeBuffer, .mediaAtRest,
                        .lockContentKeyWrap, .heartDropSidecars] {
            let row = try #require(report.rows.first(where: { $0.surface == surface }))
            #expect(row.definitelyLegacy == 1, "\(surface.rawValue) did not report its planted legacy blob")
            #expect(row.legacyCountText == "1")
            #expect(row.status == .counted, "\(surface.rawValue) reported blind spots it should not have: \(row.status)")
            #expect(!row.detail.isEmpty)
        }
        #expect(report.rowsWithoutACount.map(\.surface) == [.sealedPhotoBackup])
    }

    /// The same wiring with NOTHING planted: every countable surface reports a real, earned zero,
    /// and the uncountable one still reports no number. The counterpart to the test above — without
    /// it, an aggregator that hard-coded `1` would pass.
    @Test func anEmptyDeviceReportsEarnedZerosAndStillCannotCountTheBackup() async throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let ownRoot = try makeOwnPhotoRoot()
        let wallRoot = try makeDirectory("wall")
        let heartDropRoot = try makeDirectory("heartdrop")
        let narrativeScope = uniqueNarrativeBufferScope()
        let lockService = uniqueLockService()
        defer {
            for root in [ownRoot, wallRoot, heartDropRoot, narrativeScope.directory] {
                try? FileManager.default.removeItem(at: root)
            }
            KeychainItem.deleteAll(service: lockService)
            KeychainItem.deleteAll(service: narrativeScope.keychainService)
        }

        let report = await CryptoFormatCensus.run(inputs: CryptoFormatCensus.Inputs(
            sealedStore: controller,
            ownPhotoDocumentsDirectory: ownRoot,
            friendWallSupportDirectory: wallRoot,
            narrativeScope: narrativeScope,
            lockKeychainService: lockService,
            heartDropDirectory: heartDropRoot
        ))

        for row in report.rows where row.surface != .sealedPhotoBackup {
            #expect(row.definitelyLegacy == 0, "\(row.surface.rawValue) should have counted a clean zero")
            #expect(row.status == .counted)
        }
        let backup = try #require(report.rows.first(where: { $0.surface == .sealedPhotoBackup }))
        #expect(backup.definitelyLegacy == nil)
    }

    // MARK: - The surface that cannot be counted

    /// `SealedPhotoBackupService` is always present, always `uncountable`, and its number is `nil` —
    /// never `0`. A zero here would read as "this surface is clean" and license Phase 3's delete on
    /// a surface that has no marker to count in the first place.
    @Test func theSealedPhotoBackupRowIsPresentUncountableAndNeverZero() {
        let row = CryptoFormatCensus.sealedPhotoBackupRow
        #expect(row.surface == .sealedPhotoBackup)
        #expect(row.definitelyLegacy == nil)
        #expect(row.legacyCountText == "—")
        #expect(row.legacyCountText != "0")
        #expect(!row.hasCount)
        guard case .uncountable = row.status else {
            Issue.record("the sealed photo backup row must be uncountable, not \(row.status)")
            return
        }
        // The row has to SAY why, not merely be flagged: the debug surface renders these two lines.
        #expect(row.detail.contains("UNAVAILABLE"))
        #expect(row.caveat?.isEmpty == false, "the row must say WHY it cannot be counted")
        #expect(CryptoFormatCensusSurface.allCases.contains(.sealedPhotoBackup))
    }

    /// The row's refusal is SCOPED, not absolute: the number cannot be produced *here*, and the row
    /// has to say where it can. Since the Phase 3 gate readout ships beside this census and reads
    /// exactly that number on request, a row still reading as an absolute would send a Phase 3
    /// session looking for an instrument it already has.
    @Test func theSealedPhotoBackupRowNamesTheReadoutRatherThanReadingAsAnAbsolute() throws {
        let caveat = try #require(CryptoFormatCensus.sealedPhotoBackupRow.caveat)
        #expect(caveat.contains("it is not a number a census can produce"),
                "the census's own refusal must survive verbatim")
        #expect(caveat.contains("Phase 3 gate readout"),
                "the row must name where the number CAN be read")
        #expect(caveat.contains("network fetch"),
                "and it must state the cost that is precisely why this census does not pay it")
    }

    // MARK: - Indeterminate is not zero

    /// Every way a surface can fail to produce a number maps to a row with **no** count and a stated
    /// reason. This is the row-model half of the `Int?` discipline the per-surface censuses
    /// established: they refuse to return `0`, and the aggregator must not invent one on their
    /// behalf.
    @Test func indeterminateReadingsNeverRenderAsAZeroCount() throws {
        let unreadableBuffer = CryptoFormatCensus.row(forPendingNarrative: PendingNarrativeBufferFormatCensus(
            format: .unreadable(reason: "Operation not permitted"),
            fileURL: URL(fileURLWithPath: "/dev/null/pending-narratives.bin")
        ))
        let lockedKeychain = CryptoFormatCensus.row(forLockWrap: LockWrapFormatCensusReport(
            keychainService: "com.fernlet.lock.test.census.unreadable",
            account: LockWrapFormatCensus.account,
            state: .unreadable(errSecInteractionNotAllowed)
        ))
        let emptyWrap = CryptoFormatCensus.row(forLockWrap: LockWrapFormatCensusReport(
            keychainService: "com.fernlet.lock.test.census.empty",
            account: LockWrapFormatCensus.account,
            state: .malformedEmpty
        ))
        let unloadedStore = CryptoFormatCensus.row(
            forSealedColumns: .failed("The sealed store is not loaded — there is nothing to census.")
        )

        for row in [unreadableBuffer, lockedKeychain, emptyWrap, unloadedStore] {
            #expect(row.definitelyLegacy == nil, "\(row.surface.rawValue) turned an indeterminate reading into a number")
            #expect(row.legacyCountText == "—")
            #expect(row.legacyCountText != "0")
            #expect(!row.hasCount)
            guard case let .indeterminate(reason) = row.status else {
                Issue.record("\(row.surface.rawValue) should be indeterminate, not \(row.status)")
                continue
            }
            #expect(!reason.isEmpty, "an indeterminate row must say what stopped it")
        }
    }

    /// A count from a pass with blind spots keeps its number — it is a real lower bound — but is
    /// marked so nobody reads it as proof. The three sources are one per surface shape: a truncated
    /// row scan, an unreadable media file, and an unreadable sidecar.
    @Test func blindSpotsKeepTheNumberAndMarkItALowerBound() throws {
        let truncated = CryptoFormatCensus.row(forSealedColumns: .counted(SealedColumnFormatCensusResult(
            columns: [
                SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext"):
                    SealedColumnFormatTally(v3Marked: 4, unprefixed: 2)
            ],
            rowsScanned: 6,
            rowsAvailable: 9,
            truncated: true,
            rowCap: 6
        )))
        #expect(truncated.definitelyLegacy == 2)
        #expect(truncated.detail.contains("v3 ≤4"), "marked buckets must be printed as upper bounds")
        guard case let .countedWithBlindSpots(truncationReason) = truncated.status else {
            Issue.record("a truncated scan must be marked as a lower bound, not \(truncated.status)")
            return
        }
        #expect(truncationReason.contains("lower bound"))

        let blindMedia = CryptoFormatCensus.row(forMedia: MediaAtRestFormatCensusReport(locations: [
            MediaAtRestFormatLocationCensus(
                url: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.blind"),
                kind: .directory,
                existed: true,
                tally: MediaAtRestFormatTally(unprefixedLegacyOrUnrecognized: 3, indeterminate: 1)
            )
        ]))
        #expect(blindMedia.definitelyLegacy == 3)
        #expect(blindMedia.hasCount)
        if case .countedWithBlindSpots = blindMedia.status {} else {
            Issue.record("an unreadable media file must mark the count as a lower bound, not \(blindMedia.status)")
        }

        let blindSidecars = CryptoFormatCensus.row(forHeartDrop: HeartDropSidecarFormatCensus.Report(
            directory: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.sidecars"),
            files: [
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .outbox, fileName: "HeartDropOutbox.json", state: .legacySealed
                ),
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .peerBundles, fileName: "HeartDropPeerBundles.json", state: .unreadable
                ),
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .dedup, fileName: "HeartDropDedup.json", state: .v2Sealed
                ),
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .outboxQuarantine, fileName: "HeartDropOutbox.json.corrupt", state: .absent
                )
            ]
        ))
        #expect(blindSidecars.definitelyLegacy == 1)
        if case .countedWithBlindSpots = blindSidecars.status {} else {
            Issue.record("an unreadable sidecar must mark the count as a lower bound, not \(blindSidecars.status)")
        }
        #expect(blindSidecars.detail.contains("HeartDropOutbox.json"), "the row names the files it classified")
    }

    // MARK: - Caveats that are not blind spots

    /// THE NECESSARY-NOT-SUFFICIENT RIDER. The sealed-column detail line advertises its legacy
    /// number as "exact", and it is — but only of the unprefixed bucket. A legacy blob whose first
    /// nonce byte collides with a marker (~1/256 per marker) is counted as MARKED, so while any
    /// marked blob exists, a zero is necessary and not sufficient. The row must carry that where a
    /// reader will see it, not only in `SealedColumnFormatTally`'s doc comment, because the reader
    /// of this row is the person deciding whether Phase 3 may delete the legacy reader.
    @Test func theSealedColumnRowCarriesTheCollisionRiderWheneverMarkedBlobsExist() throws {
        let row = CryptoFormatCensus.row(forSealedColumns: .counted(SealedColumnFormatCensusResult(
            columns: [
                SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext"):
                    SealedColumnFormatTally(v3Marked: 5, v2Marked: 2, unprefixed: 0)
            ],
            rowsScanned: 7,
            rowsAvailable: 7,
            truncated: false,
            rowCap: 20_000
        )))

        #expect(row.definitelyLegacy == 0)
        #expect(row.detail.contains("exact"), "the detail line still claims the unprefixed count is exact")
        let caveat = try #require(row.caveat, "an exact zero beside 7 marked blobs must not stand unqualified")
        #expect(caveat.contains("necessary, not sufficient"))
        #expect(caveat.contains("7"), "the rider names how many blobs could be collided legacy: v3Marked + v2Marked")
        if case .countedWithBlindSpots = row.status {} else {
            Issue.record("a zero with marked blobs beside it is not a clean count: \(row.status)")
        }

        // And the rider is NOT permanent noise: a store with nothing marked earns a clean status.
        let unmarked = CryptoFormatCensus.row(forSealedColumns: .counted(SealedColumnFormatCensusResult(
            columns: [
                SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext"):
                    SealedColumnFormatTally(unprefixed: 3, emptyOrNil: 1)
            ],
            rowsScanned: 4,
            rowsAvailable: 4,
            truncated: false,
            rowCap: 20_000
        )))
        #expect(unmarked.status == .counted)
        #expect(unmarked.caveat == nil)
    }

    /// Files matching NEITHER marker — a v0 plaintext sidecar awaiting its silent seal-on-load
    /// migration, or garbage — are unmigrated or unproven, and the surface's own census says so via
    /// `Report.isClean`. Keying the row off `isConclusive` instead (which asks only "was everything
    /// readable") scored a corpus full of them as a clean count. The row must consult `isClean` and
    /// name both buckets, because they need different responses: unreadable is retakeable after
    /// unlock, unrecognised is not.
    @Test func unrecognisedSidecarsAreACaveatEvenWhenEveryFileWasReadable() throws {
        let row = CryptoFormatCensus.row(forHeartDrop: HeartDropSidecarFormatCensus.Report(
            directory: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.unsealed"),
            files: [
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .outbox, fileName: "HeartDropOutbox.json", state: .unsealedOrUnrecognized
                ),
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .peerBundles, fileName: "HeartDropPeerBundles.json", state: .unsealedOrUnrecognized
                ),
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .dedup, fileName: "HeartDropDedup.json", state: .v2Sealed
                ),
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: .outboxQuarantine, fileName: "HeartDropOutbox.json.corrupt", state: .absent
                )
            ]
        ))

        // Every file was READ, so the old `isConclusive` test would have called this clean.
        #expect(row.definitelyLegacy == 0)
        let caveat = try #require(row.caveat, "two unmigrated sidecars must not read as a clean zero")
        #expect(caveat.contains("2"))
        #expect(caveat.contains("neither marker"))

        // A legacy count, by contrast, is NOT a caveat — the number is exact and the row prints it.
        let legacyOnly = CryptoFormatCensus.row(forHeartDrop: HeartDropSidecarFormatCensus.Report(
            directory: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.legacy"),
            files: HeartDropSidecarFormatCensus.Sidecar.allCases.map { sidecar in
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: sidecar,
                    fileName: sidecar.rawValue,
                    state: sidecar == .outbox ? .legacySealed : .absent
                )
            }
        ))
        #expect(legacyOnly.definitelyLegacy == 1)
        #expect(legacyOnly.status == .counted, "an exact legacy count is a clean COUNT: \(legacyOnly.status)")
    }

    /// Pre-sealing plaintext JPEGs are a SECOND legacy generation the primary number deliberately
    /// excludes — their plaintext is on disk, and nothing about deleting `gcmOpen`'s legacy branch
    /// heals them. They were absent from every caveat, so a media row could show "legacy 0" with a
    /// pile of cleartext photos beside it and no word about them.
    @Test func plaintextJPEGsAreNamedInTheMediaCaveat() throws {
        let row = CryptoFormatCensus.row(forMedia: MediaAtRestFormatCensusReport(locations: [
            MediaAtRestFormatLocationCensus(
                url: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.meal"),
                kind: .directory,
                existed: true,
                tally: MediaAtRestFormatTally(v2Marked: 10, plaintextJPEG: 4)
            )
        ]))

        #expect(row.definitelyLegacy == 0, "plaintext JPEGs are not in the unprefixed bucket")
        let caveat = try #require(row.caveat, "4 cleartext photos must not sit behind an unqualified zero")
        #expect(caveat.contains("4"))
        #expect(caveat.contains("plaintext"))
        #expect(caveat.contains("upgrade-on-read"), "the caveat says what does and does not heal them")
    }

    /// An all-absent media sweep counted NOTHING, and must not render as a swept-clean corpus. One
    /// absent corpus is a feature nobody used; every location absent on a running device is the
    /// signature of a census pointed at roots the store is not actually using.
    @Test func aMediaSweepThatFoundNoLocationAtAllIsNotSweptClean() throws {
        let absent = CryptoFormatCensus.row(forMedia: MediaAtRestFormatCensusReport(
            locations: (0..<8).map { index in
                MediaAtRestFormatLocationCensus(
                    url: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.gone/\(index)"),
                    kind: .directory,
                    existed: false,
                    tally: .zero
                )
            }
        ))

        #expect(absent.definitelyLegacy == 0)
        #expect(absent.detail.contains("8 of 8 locations absent"), "the row states how much of the sweep found nothing")
        let caveat = try #require(absent.caveat, "a sweep of eight paths that are not there is not a clean zero")
        #expect(caveat.contains("nothing was there to count"))

        // A partially-absent sweep keeps the detail note and stays a clean count — most devices.
        let partial = CryptoFormatCensus.row(forMedia: MediaAtRestFormatCensusReport(locations: [
            MediaAtRestFormatLocationCensus(
                url: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.here"),
                kind: .directory,
                existed: true,
                tally: MediaAtRestFormatTally(v2Marked: 2)
            ),
            MediaAtRestFormatLocationCensus(
                url: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus.wall"),
                kind: .directory,
                existed: false,
                tally: .zero
            )
        ]))
        #expect(partial.detail.contains("1 of 2 locations absent"))
        #expect(partial.status == .counted, "one absent corpus is normal, not a blind spot: \(partial.status)")
    }

    /// The lock row's `absent` state has THREE legitimate readings, and the third one is a fault:
    /// on enclave-less hardware a configured lock's wrap can simply have gone missing. The row text
    /// listed two of them, which turns the one reading that means something is wrong into silence.
    @Test func theLockRowsAbsentTextKeepsAllThreeReadings() throws {
        let row = CryptoFormatCensus.row(forLockWrap: LockWrapFormatCensusReport(
            keychainService: "com.fernlet.lock.test.census.absent",
            account: LockWrapFormatCensus.account,
            state: .absent
        ))

        #expect(row.definitelyLegacy == 0, "an absent wrap row is a real zero")
        #expect(row.status == .counted)
        #expect(row.detail.contains("no lock configured"))
        #expect(row.detail.contains("enclave-bound"))
        #expect(row.detail.contains("gone missing"), "the third reading — a fault — must not be dropped")
    }

    // MARK: - The fold

    /// The report is exactly six rows, one per surface, in a stable order — the shape the DEBUG
    /// view renders and the shape the plan's exit criterion is stated in.
    @Test func theReportIsOneRowPerSurfaceInSurfaceOrder() {
        let report = CryptoFormatCensus.report(from: CryptoFormatCensus.Readings(
            sealedColumns: .failed("not loaded"),
            pendingNarrative: PendingNarrativeBufferFormatCensus(
                format: .absent,
                fileURL: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus/pending-narratives.bin")
            ),
            media: MediaAtRestFormatCensusReport(locations: []),
            lockWrap: LockWrapFormatCensusReport(
                keychainService: "com.fernlet.lock.test.census.absent",
                account: LockWrapFormatCensus.account,
                state: .absent
            ),
            heartDrop: HeartDropSidecarFormatCensus.Report(
                directory: URL(fileURLWithPath: "/tmp/fernlet.tests.cryptoCensus"),
                files: HeartDropSidecarFormatCensus.Sidecar.allCases.map { sidecar in
                    HeartDropSidecarFormatCensus.FileReading(
                        sidecar: sidecar,
                        fileName: sidecar.rawValue,
                        state: .absent
                    )
                }
            )
        ))

        #expect(report.rows.count == CryptoFormatCensusSurface.allCases.count)
        #expect(report.rows.map(\.surface) == CryptoFormatCensusSurface.allCases)
        #expect(report.allSurfacesReported)
        // Absent files and an absent keychain row are earned zeros; the unloaded store and the
        // backup are not — and the two must not blur.
        #expect(report.rowsWithoutACount.map(\.surface) == [.sealedColumns, .sealedPhotoBackup])
        for row in report.rows {
            #expect(!row.displayName.isEmpty)
            #expect(!row.detail.isEmpty)
        }
    }
}
