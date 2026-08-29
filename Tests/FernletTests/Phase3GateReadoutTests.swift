// Phase3GateReadoutTests.swift
// FernletTests
//
// The fail-loud discipline of the Phase 3 gate readout (Docs/Plan-Crypto-Standardization-2026-08-27.md
// §Phase 3), driven as PURE functions over injected readings — no `FernletStore`, no CloudKit, no
// device. Every fixture is hand-built, exactly as `CryptoFormatCensusTests` drives
// `CryptoFormatCensus.report(from:)`.
//
// The failure mode every assertion below is shaped around: this readout is the instrument a Phase 3
// session reads before DELETING legacy readers. A row that manufactures a clean verdict — from a
// missing observation, an empty manifest, a keyless revalidation, a residue subtraction with no
// witness — hands that session the reading it is gated on. So the pins are not "does the happy path
// discharge"; they are "does each way of manufacturing a pass get refused, by name".
//
// Deliberately NOT wrapped in `#if DEBUG`, for the reason `CryptoFormatCensusTests` states: the
// scheme pins the test action to Debug, so the symbols are always there, and guarding the suite
// would trade a compile error nobody can miss for a suite that evaporates silently.

import CloudKitSync
import Foundation
import Security
import Testing
import FernletFoundation
import FernletLock
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit
@testable import Fernlet

/// Pins ``Phase3GateReadoutBuilder``, ``MediaResidueAudit`` and ``Phase3GateReportBuilder``.
///
/// `.serialized` following `CryptoFormatCensusTests`: nothing here touches disk, but the suite reads
/// `ProcessInfo` environment and builds `UserDefaults` suites, and the house discipline for anything
/// near the sealed-store fixtures is serial.
@Suite(.serialized)
struct Phase3GateReadoutTests {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    private func stamp(_ label: String, offset: TimeInterval = 0) -> Phase3Stamp {
        Phase3Stamp(label: label, takenAt: Self.epoch.addingTimeInterval(offset))
    }

    private func environment(
        escrowRouteCommitted: Bool = true,
        lockConfigured: Bool = true
    ) -> Phase3GateEnvironment {
        Phase3GateEnvironment(
            sealedBackupOwnPhotosEnabled: true,
            escrowRouteCommitted: escrowRouteCommitted,
            skipSealedRestoreEnvSet: false,
            lockConfigured: lockConfigured,
            privateHubUnlocked: false,
            duressSessionActive: false,
            ownPhotoBackupPassInFlight: false,
            lastFullPassCompletedAt: nil,
            hasEmbeddedProvisioningProfile: false,
            systemVersion: "iOS 26.0",
            deviceModel: "iPhone17,1"
        )
    }

    private func latches(
        sealedColumn: Bool = true,
        mediaAtRest: Bool = true,
        ownPhotoKey: Bool = true
    ) -> Phase3LatchReadings {
        Phase3LatchReadings(
            sealedColumn: sealedColumn,
            mediaAtRest: mediaAtRest,
            ownPhotoKey: ownPhotoKey,
            heartDropSidecar: true,
            sealedPhotoBackup: true,
            lockWrapRow: true
        )
    }

    /// A clean sealed-column census: one column, everything v3.
    private func cleanColumnCensus(unprefixed: Int = 0, marked: Int = 0) -> SealedColumnFormatCensusResult {
        SealedColumnFormatCensusResult(
            columns: [
                SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext"):
                    SealedColumnFormatTally(v3Marked: 4, v2Marked: marked, unprefixed: unprefixed)
            ],
            rowsScanned: 4 + marked + unprefixed,
            rowsAvailable: 4 + marked + unprefixed,
            truncated: false,
            rowCap: 20_000
        )
    }

    private func cleanColumnPass() -> SealedColumnMigrationResult {
        SealedColumnMigrationResult(
            columns: [
                SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext"):
                    SealedColumnMigrationTally(openedV3: 4)
            ],
            rowsScanned: 4,
            rowsAvailable: 4
        )
    }

    private func keyedWitness(
        offset: TimeInterval = 0,
        passes: [SealedColumnMigrationResult]? = nil
    ) -> SealedColumnPassWitness {
        SealedColumnPassWitness(
            stamp: stamp("sealed-column keyed run", offset: offset),
            revalidation: nil,
            latched: true,
            passes: passes ?? [cleanColumnPass()]
        )
    }

    // MARK: - Sealed columns

    /// A missing observation renders `.notTaken` — never `.discharged`, and never `.blocked`. A
    /// blocked verdict would be its own lie: nothing answered against the gate, nobody asked.
    @Test func aSealedColumnGateWithNoKeyedPassIsNotTakenRatherThanDischargedOrBlocked() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: true,
            witness: nil,
            censusStamp: stamp("marker census"),
            passInFlight: false
        )
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("no keyed pass"))
        #expect(!row.isDischarged)
        #expect(!row.witnesses.isEmpty, "every row must name at least one witness kind")
    }

    /// A `.confirmed` revalidation with ZERO passes never discharges, and the row says the pass was
    /// KEYLESS. That state is completely silent in the app today — `revalidate` returns `.confirmed`
    /// before any audit line — and a bare `latch == true` beside it would read as success.
    @Test func aConfirmedRevalidationWithNoPassesSaysTheWitnessWasKeyless() {
        let witness = SealedColumnPassWitness(
            stamp: stamp("sealed-column revalidation"),
            revalidation: .confirmed,
            latched: true,
            passes: []
        )
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus(marked: 3)),
            latch: true,
            witness: witness,
            censusStamp: stamp("marker census"),
            passInFlight: false
        )
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("KEYLESS"))
        #expect(reason.contains("collided"))
        #expect(row.caveats.contains { $0.contains("collided legacy") },
                "the ~1/256 sliver must be named while marked blobs exist")
    }

    /// A pass that stopped ONLY on key revocation is a clean stop, not a witness.
    @Test func aPassStoppedOnlyByKeyRevocationIsNotTakenRatherThanSuccess() {
        let stopped = SealedColumnMigrationResult(
            columns: [:],
            notAttempted: [.keyRevoked: 12],
            rowsScanned: 0,
            rowsAvailable: 12
        )
        #expect(stopped.stoppedOnlyByKeyRevocation)
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: false,
            witness: keyedWitness(passes: [stopped]),
            censusStamp: stamp("marker census"),
            passInFlight: false
        )
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("re-locked"))
    }

    /// A keyed pass that ran and was NOT clean renders `.blocked` naming every blocking bucket.
    @Test func anUncleanKeyedPassBlocksAndNamesItsBuckets() {
        let dirty = SealedColumnMigrationResult(
            columns: [
                SealedColumnIdentifier(entityName: "JournalNarrative", attributeName: "textCiphertext"):
                    SealedColumnMigrationTally(indeterminate: 2, unopenableUnprefixed: 1)
            ],
            rowsScanned: 3,
            rowsAvailable: 3,
            truncated: true
        )
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: false,
            witness: keyedWitness(passes: [dirty]),
            censusStamp: stamp("marker census"),
            passInFlight: false
        )
        guard case let .blocked(reason) = row.verdict else {
            Issue.record("expected .blocked, got \(row.verdict)")
            return
        }
        #expect(reason.contains("indeterminate 2"))
        #expect(reason.contains("unopenableUnprefixed 1"))
        #expect(reason.contains("truncated"))
    }

    /// A census reading taken BEFORE the keyed pass beside it does not silently pair with it: the row
    /// renders the ordering as a caveat and refuses to discharge.
    @Test func aCensusStampOlderThanTheKeyedPassRendersTheOrderingCaveatAndDoesNotDischarge() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: true,
            witness: keyedWitness(offset: 60),
            censusStamp: stamp("marker census", offset: 0),
            passInFlight: false,
            resetTakenAt: Self.epoch.addingTimeInterval(30)
        )
        #expect(!row.isDischarged)
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("BEFORE"))
        #expect(row.caveats.contains { $0.contains("ORDERING") })
        #expect(row.stamps.count == 2, "a row that folds two observations must print both stamps")
    }

    /// Both witnesses answering, in the right order, is the only shape that discharges.
    @Test func aCensusZeroTakenAfterACleanKeyedPassDischarges() {
        let row = dischargingSealedColumnRow()
        #expect(row.verdict == .discharged)
    }

    /// The only shape that discharges, assembled once: a non-empty corpus, a latch reset taken this
    /// sitting, a keyed clean pass AFTER it, and a census re-taken after the pass.
    private func dischargingSealedColumnRow(
        census: SealedColumnFormatCensusResult? = nil
    ) -> Phase3GateRow {
        Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(census ?? cleanColumnCensus()),
            latch: true,
            witness: keyedWitness(offset: 10),
            censusStamp: stamp("marker census", offset: 30),
            passInFlight: false,
            resetTakenAt: Self.epoch
        )
    }

    /// A store-wide floor lets ONE exercised entity carry three that were never written.
    ///
    /// The owner's 2026-08-28 sitting was exactly this shape: one `JournalNarrative` row, and zero
    /// rows in `MenstrualNarrative`, `IntimacyLog` and `WorryNarrative`. The census seeds EVERY
    /// censused column with a zero tally, so the untouched entities are present and readable — the
    /// verdict simply was not looking at them. Deleting the legacy rung retires the read path for
    /// every column alike, so coverage has to be per column.
    @Test func aColumnThatContributedNoValueMakesTheSealedGateVacuous() {
        let exercised = SealedColumnIdentifier(entityName: "JournalNarrative", attributeName: "textCiphertext")
        let untouched = SealedColumnIdentifier(entityName: "IntimacyLog", attributeName: "noteCiphertext")
        let census = SealedColumnFormatCensusResult(
            columns: [exercised: SealedColumnFormatTally(v3Marked: 1),
                      untouched: SealedColumnFormatTally()],
            rowsScanned: 1, rowsAvailable: 1, truncated: false, rowCap: 20_000
        )
        let row = dischargingSealedColumnRow(census: census)
        guard case let .vacuous(reason) = row.verdict else {
            Issue.record("expected .vacuous, got \(row.verdict)")
            return
        }
        #expect(reason.contains("IntimacyLog.noteCiphertext"))
        #expect(!row.isDischarged)
    }

    /// All three main sidecars absent is NOT a converted corpus — it is no corpus.
    ///
    /// `.absent` and `.empty` are both non-blocking, so the verdict walked its whole switch without
    /// appending anything and fell through to `.discharged`. That is the vacuous reading wearing the
    /// discharge's face, and the owner's device produced it.
    @Test func heartDropWithNoSealedByteAnywhereIsVacuousRatherThanDischarged() {
        let report = sidecarReport([.outbox: .absent, .peerBundles: .absent, .dedup: .absent])
        let row = Phase3GateReadoutBuilder.row(forHeartDrop: report, latch: true, stamp: stamp("heart-drop"))
        guard case let .vacuous(reason) = row.verdict else {
            Issue.record("expected .vacuous, got \(row.verdict)")
            return
        }
        #expect(reason.contains("no heart-drop bytes AT ALL"))
        #expect(!row.isDischarged)
    }

    /// One sealed sidecar is enough to make the reading real, so the arm above does not over-refuse.
    @Test func heartDropWithOneSealedSidecarStillDischarges() {
        let report = sidecarReport([.outbox: .v2Sealed, .peerBundles: .absent, .dedup: .absent])
        let row = Phase3GateReadoutBuilder.row(forHeartDrop: report, latch: true, stamp: stamp("heart-drop"))
        #expect(row.isDischarged)
    }

    /// A discharge is refused outright while a keyed pass is writing the corpus the scan read.
    @Test func aSealedColumnPassInFlightRefusesADischarge() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: true,
            witness: keyedWitness(offset: 10),
            censusStamp: stamp("marker census", offset: 30),
            passInFlight: true,
            resetTakenAt: Self.epoch
        )
        #expect(!row.isDischarged)
    }

    /// A census that could not run is `.unavailable`, never a zero.
    @Test func aFailedSealedColumnCensusIsUnavailableRatherThanAZero() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .failed("the store is not loaded"),
            latch: true,
            witness: keyedWitness(),
            censusStamp: stamp("marker census"),
            passInFlight: false
        )
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("not a zero"))
    }

    /// A census whose zero is over an EMPTY corpus is `.vacuous`, never `.discharged`.
    ///
    /// Both halves are trivially true there: the tally is empty so `unprefixed == 0`, and a pass
    /// over zero pages is `isClean` by construction — which also means the per-page content key was
    /// never vended, so that "keyed" pass opened nothing and resolved none of the collided-marker
    /// sliver it exists for. A device immediately after Delete everything is exactly this shape.
    @Test func aZeroRowCorpusIsVacuousRatherThanDischarged() {
        let empty = SealedColumnFormatCensusResult(columns: [:], rowsScanned: 0, rowsAvailable: 0,
                                                   truncated: false, rowCap: 20_000)
        let row = dischargingSealedColumnRow(census: empty)
        guard case let .vacuous(reason) = row.verdict else {
            Issue.record("expected .vacuous, got \(row.verdict)")
            return
        }
        #expect(reason.contains("EMPTY corpus"))
        #expect(!row.isDischarged)
    }

    /// The variant a bare `rowsAvailable > 0` floor misses: rows are present, and every sealed
    /// column value on them is nil. `emptyOrNil` is counted separately from `unprefixed`, so this
    /// prints a healthy non-zero row count with no visible tell at all.
    @Test func aCorpusWhoseSealedValuesAreAllEmptyIsAlsoVacuous() {
        let allEmpty = SealedColumnFormatCensusResult(
            columns: [
                SealedColumnIdentifier(entityName: "MenstrualNarrative", attributeName: "notesCiphertext"):
                    SealedColumnFormatTally(emptyOrNil: 120)
            ],
            rowsScanned: 40, rowsAvailable: 40, truncated: false, rowCap: 20_000
        )
        let row = dischargingSealedColumnRow(census: allEmpty)
        guard case let .vacuous(reason) = row.verdict else {
            Issue.record("expected .vacuous, got \(row.verdict)")
            return
        }
        #expect(reason.contains("0 sealed column values"))
    }

    /// A TRUNCATED census's zero describes a subset, so it is `.unavailable` — not a count of the
    /// corpus, and certainly not a discharge.
    @Test func aTruncatedCensusZeroIsUnavailableRatherThanExact() {
        let capped = SealedColumnFormatCensusResult(
            columns: [
                SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext"):
                    SealedColumnFormatTally(v3Marked: 20_000)
            ],
            rowsScanned: 20_000, rowsAvailable: 20_400, truncated: true, rowCap: 20_000
        )
        let row = dischargingSealedColumnRow(census: capped)
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("SUBSET"))
    }

    /// The plan's gate is a FRESH keyed pass run at gate time. A keyed witness the process happened
    /// to have — the one the first hub unlock of the day produced — never discharges, because it
    /// says nothing about rows written since, and post-pass legacy rows whose first byte collides
    /// with a marker are invisible to `unprefixed == 0`.
    @Test func aKeyedPassWithNoLatchResetThisSittingIsNotTaken() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: true,
            witness: keyedWitness(offset: 0),
            censusStamp: stamp("marker census", offset: 30),
            passInFlight: false
        )
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("no latch reset was taken this sitting"))
    }

    /// ...and a keyed pass that PREDATES this sitting's reset is refused by name.
    @Test func aKeyedPassPredatingTheSittingsResetIsNotTaken() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: true,
            witness: keyedWitness(offset: 0),
            censusStamp: stamp("marker census", offset: 60),
            passInFlight: false,
            resetTakenAt: Self.epoch.addingTimeInterval(30)
        )
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("predates this sitting"))
    }

    /// A scan that OVERLAPPED a keyed pass is refused even though the render-time flag is clear:
    /// the marker counts are neither the before nor the after state.
    @Test func aScanThatOverlappedAKeyedPassIsRefusedAfterThePassLands() {
        let row = Phase3GateReadoutBuilder.row(
            forSealedColumns: .counted(cleanColumnCensus()),
            latch: true,
            witness: keyedWitness(offset: 10),
            censusStamp: stamp("marker census", offset: 30),
            passInFlight: false,
            overlappedKeyedPass: true,
            resetTakenAt: Self.epoch
        )
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("writing the corpus while this scan ran"))
    }

    // MARK: - Media arithmetic

    private func mediaReport(
        locations: [(MediaCorpusLabel, MediaAtRestFormatTally, Bool)],
        ownRoot: URL,
        wallRoot: URL
    ) -> MediaAtRestFormatCensusReport {
        let expected = MediaCorpusLabel.expectedURLs(
            ownPhotoDocumentsDirectory: ownRoot,
            friendWallSupportDirectory: wallRoot
        )
        let byLabel = Dictionary(uniqueKeysWithValues: expected.map { ($0.label, $0.url) })
        let rows = locations.compactMap { entry -> MediaAtRestFormatLocationCensus? in
            guard let url = byLabel[entry.0] else { return nil }
            let kind: MediaAtRestFormatLocationCensus.Kind =
                (entry.0 == .progressIndex || entry.0 == .wallIndexSealed || entry.0 == .wallIndexLegacyPlaintext)
                ? .file : .directory
            return MediaAtRestFormatLocationCensus(url: url, kind: kind, existed: entry.2, tally: entry.1)
        }
        return MediaAtRestFormatCensusReport(locations: rows)
    }

    private func mediaWitness(
        unopenable: Int,
        examined: Int,
        offset: TimeInterval = 0,
        sealedPlaintext: Int = 0,
        latchBefore: Bool = true,
        latchAfter: Bool = true
    ) -> MediaPassWitness {
        MediaPassWitness(
            stamp: stamp("media at-rest pass", offset: offset),
            result: MediaAtRestFormatMigrationResult(examined: examined,
                                                     convertedPlaintext: sealedPlaintext,
                                                     unopenableUnprefixed: unopenable),
            latchBefore: latchBefore,
            latchAfter: latchAfter
        )
    }

    private var ownRoot: URL { URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Documents") }
    private var wallRoot: URL { URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Library/Proximity") }

    /// With no `MediaPassWitness` the subtraction has no K term, so `unaccountedUnprefixed` is nil —
    /// **not a computed zero** — and the gate renders `.notTaken`. This is the fail-loud direction
    /// that a `?? 0` anywhere in the fold would silently destroy.
    @Test func withNoMediaWitnessTheSubtractionIsNilAndTheGateIsNotTaken() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 10), true)],
            ownRoot: own, wallRoot: wall
        )
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: nil)
        #expect(audit.unaccountedUnprefixed == nil)
        #expect(audit.passUnopenableUnprefixed == nil)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: nil,
                                               passInFlight: false, censusStamp: stamp("marker census"))
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("no K term"))
    }

    /// An unprefixed byte in a BORN-SEALED location renders `.unopenableCandidate`, not `.blocking`.
    /// The regression test for the rule that would have rendered BLOCKED on a device the migrator
    /// itself considers Phase-3-safe, permanently, with no remediation.
    @Test func anUnprefixedByteInABornSealedLocationIsACandidateNotBlocking() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.recipePhotos, MediaAtRestFormatTally(unprefixedLegacyOrUnrecognized: 2), true)],
            ownRoot: own, wallRoot: wall
        )
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: nil)
        guard case .unopenableCandidate = audit.locations.first?.residueVerdict else {
            Issue.record("expected .unopenableCandidate, got \(String(describing: audit.locations.first?.residueVerdict))")
            return
        }
        // ...and a live pass that ACCOUNTS for them lets the gate discharge.
        let accounted = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                               friendWallSupportDirectory: wall,
                                               latches: latches(),
                                               witness: mediaWitness(unopenable: 2, examined: 2))
        #expect(accounted.unaccountedUnprefixed == 0)
        let row = Phase3GateReadoutBuilder.row(forMedia: accounted, latches: latches(),
                                               witness: mediaWitness(unopenable: 2, examined: 2),
                                               passInFlight: false, censusStamp: stamp("marker census"))
        #expect(row.verdict == .discharged)
    }

    /// A corpus that is nothing but friend-wall files discharges over the wrong bytes.
    ///
    /// The owner's 2026-08-28 sitting read 51 files, every one of them wall (25 photos, 25 thumbs,
    /// one sealed index), while `MealPhotos/`, `RecipePhotos/` and `ProgressPhotos/` held zero. The
    /// wall is born sealed and `dispatchUnprefixedWall` deliberately routes its unopenable bytes
    /// clear of `isClean`, so every clause of this gate can be satisfied by bytes that were never
    /// capable of failing it. MealPhotos — the one corpus with a legitimate pre-sealing plaintext
    /// generation — is the corpus the gate is actually about.
    @Test func aWallOnlyCorpusIsVacuousRatherThanDischarged() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.wallPhotos, MediaAtRestFormatTally(v2Marked: 25), true),
                        (.wallThumbnails, MediaAtRestFormatTally(v2Marked: 25), true),
                        (.wallIndexSealed, MediaAtRestFormatTally(v2Marked: 1), true)],
            ownRoot: own, wallRoot: wall
        )
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(),
                                           witness: mediaWitness(unopenable: 0, examined: 51))
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(),
                                               witness: mediaWitness(unopenable: 0, examined: 51),
                                               passInFlight: false, censusStamp: stamp("marker census"))
        guard case let .vacuous(reason) = row.verdict else {
            Issue.record("expected .vacuous, got \(row.verdict)")
            return
        }
        #expect(reason.contains("FRIEND WALL"))
        #expect(!row.isDischarged)
    }

    /// A live pass that looked and accounted for NOTHING makes the location blocking — the only path
    /// to `.blocking`, and it is never reached by inference from where the bytes sit.
    @Test func aLivePassThatAccountsForNothingMakesTheLocationBlocking() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.recipePhotos, MediaAtRestFormatTally(unprefixedLegacyOrUnrecognized: 2), true)],
            ownRoot: own, wallRoot: wall
        )
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(),
                                           witness: mediaWitness(unopenable: 0, examined: 2))
        guard case .blocking = audit.locations.first?.residueVerdict else {
            Issue.record("expected .blocking, got \(String(describing: audit.locations.first?.residueVerdict))")
            return
        }
        #expect(audit.unaccountedUnprefixed == 2)
    }

    /// Residue B is subtracted EXACTLY once, and planting the same shape in a resealable location too
    /// does not double-subtract.
    @Test func residueBIsSubtractedExactlyOnceAndNeverTwice() {
        let own = ownRoot
        let wall = wallRoot
        let onlyJSON = mediaReport(
            locations: [(.wallIndexLegacyPlaintext, MediaAtRestFormatTally(unprefixedLegacyOrUnrecognized: 1), true)],
            ownRoot: own, wallRoot: wall
        )
        let auditA = MediaResidueAudit.take(report: onlyJSON, ownPhotoDocumentsDirectory: own,
                                            friendWallSupportDirectory: wall,
                                            latches: latches(),
                                            witness: mediaWitness(unopenable: 0, examined: 0))
        #expect(auditA.meshPhotoCacheUnprefixed == 1)
        #expect(auditA.unaccountedUnprefixed == 0, "residue B must be subtracted")
        guard case .namedResidue = auditA.locations.first?.residueVerdict else {
            Issue.record("residue B must be a NAMED residue, not a candidate")
            return
        }

        let alsoResealable = mediaReport(
            locations: [
                (.wallIndexLegacyPlaintext, MediaAtRestFormatTally(unprefixedLegacyOrUnrecognized: 1), true),
                (.wallPhotos, MediaAtRestFormatTally(unprefixedLegacyOrUnrecognized: 1), true)
            ],
            ownRoot: own, wallRoot: wall
        )
        let auditB = MediaResidueAudit.take(report: alsoResealable, ownPhotoDocumentsDirectory: own,
                                            friendWallSupportDirectory: wall,
                                            latches: latches(),
                                            witness: mediaWitness(unopenable: 1, examined: 1))
        #expect(auditB.censusUnprefixedTotal == 2)
        #expect(auditB.meshPhotoCacheUnprefixed == 1, "only the json location may contribute to J")
        #expect(auditB.unaccountedUnprefixed == 0)
    }

    /// Blind spots never discharge, even at zero unaccounted: a zero from a pass that could not see
    /// everything is not the observation Phase 3 is gated on.
    @Test func blindSpotsNeverDischargeEvenAtZeroUnaccounted() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 3, indeterminate: 1), true)],
            ownRoot: own, wallRoot: wall
        )
        let witness = mediaWitness(unopenable: 0, examined: 4)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        #expect(audit.unaccountedUnprefixed == 0)
        #expect(audit.hasBlindSpots)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census"))
        guard case let .blocked(reason) = row.verdict else {
            Issue.record("expected .blocked, got \(row.verdict)")
            return
        }
        #expect(reason.contains("blind spots"))
    }

    /// `allLocationsAbsent` is `.unavailable`, and it is a SEPARATE trap from the three blind-spot
    /// inputs — nothing was there to count, which is not a swept-clean corpus.
    @Test func allLocationsAbsentIsUnavailableSeparatelyFromTheBlindSpots() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: MediaCorpusLabel.allCases.map { ($0, MediaAtRestFormatTally.zero, false) },
            ownRoot: own, wallRoot: wall
        )
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(),
                                           witness: mediaWitness(unopenable: 0, examined: 0))
        #expect(audit.allLocationsAbsent)
        #expect(!audit.hasBlindSpots, "absence hides nothing, so it is not a blind spot")
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(),
                                               witness: mediaWitness(unopenable: 0, examined: 0),
                                               passInFlight: false, censusStamp: stamp("marker census"))
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("nothing was there to count"))
    }

    /// A census/pass `examined` disagreement renders a caveat rather than a silent cross-sweep
    /// subtraction.
    @Test func anExaminedDisagreementRendersACaveat() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 5), true)],
            ownRoot: own, wallRoot: wall
        )
        let witness = mediaWitness(unopenable: 0, examined: 3)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        #expect(audit.censusExaminedTotal == 5)
        #expect(audit.passExaminedTotal == 3)
        #expect(audit.examinedDisagreementCaveat != nil)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census"))
        #expect(row.caveats.contains { $0.contains("retake") })
    }

    /// A latch reading FALSE never stands alone: the row renders one of three distinct strings, and
    /// "no pass observed" is one of them.
    @Test func aFalseMediaLatchNeverRendersAsABareFalse() {
        #expect(Phase3GateReadoutBuilder.mediaLatchLine(latch: false, witness: nil, passInFlight: false)
            .contains("no pass has been observed"))
        #expect(Phase3GateReadoutBuilder.mediaLatchLine(latch: false, witness: nil, passInFlight: true)
            .contains("running now"))
        let blocked = MediaPassWitness(
            stamp: stamp("media at-rest pass"),
            result: MediaAtRestFormatMigrationResult(indeterminate: 3, abortedNoWallKey: true),
            latchBefore: false, latchAfter: false
        )
        let line = Phase3GateReadoutBuilder.mediaLatchLine(latch: false, witness: blocked, passInFlight: false)
        #expect(line.contains("indeterminate 3"))
        #expect(line.contains("abortedNoWallKey"))
    }

    /// A CONVERTING pass on a latched device is the finding, and the verdict must not swallow it.
    ///
    /// `convertedPlaintext` is the only bucket that does not survive into the post-pass census —
    /// the pass sealed those files into the current format — and the sitting's own order re-takes
    /// the census after the pass, so `U − J − K` nets to zero and the row used to render DISCHARGED
    /// beside a printed `isClean false`. Every OTHER device in this state runs no pass at all, so
    /// the one device that healed itself would have certified the fleet.
    @Test func aConvertingPassOnALatchedDeviceBlocksAndNamesTheStaleLatch() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 12), true)],
            ownRoot: own, wallRoot: wall
        )
        let witness = mediaWitness(unopenable: 0, examined: 12, sealedPlaintext: 12)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        #expect(audit.unaccountedUnprefixed == 0, "the re-taken census cannot see the healed blobs")
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census", offset: 30))
        guard case let .blocked(reason) = row.verdict else {
            Issue.record("expected .blocked, got \(row.verdict)")
            return
        }
        #expect(reason.contains("convertedPlaintext 12"))
        #expect(reason.contains("STALE latch"))
        #expect(row.evidence.contains { $0.contains("blocking buckets: convertedPlaintext 12") },
                "the buckets must be printed whether or not the verdict turns on them")
    }

    /// A census taken BEFORE the pass beside it cannot be quoted as clause (b): U and K would not
    /// describe one filesystem state.
    @Test func aMediaCensusTakenBeforeThePassIsNotTaken() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 3), true)],
            ownRoot: own, wallRoot: wall
        )
        let witness = mediaWitness(unopenable: 0, examined: 3, offset: 60)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census", offset: 0))
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("BEFORE"))
    }

    /// The media latch may never MOVE across a readout-funded pass: it is gate part (a), and a latch
    /// this page minted from the foreground would read next launch exactly like an earned one.
    @Test func aLatchThatMovedAcrossThePassMakesTheGateUnanswerable() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 3), true)],
            ownRoot: own, wallRoot: wall
        )
        let witness = mediaWitness(unopenable: 0, examined: 3, latchBefore: false, latchAfter: true)
        #expect(witness.latchMoved)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census", offset: 30))
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("MOVED"))
    }

    /// A NEGATIVE subtraction is `.unavailable`, not a blocked verdict quoting a negative count:
    /// nothing answered against the gate, the arithmetic became unanswerable.
    @Test func aNegativeResidueSubtractionIsUnavailableRatherThanANegativeBlock() {
        let own = ownRoot
        let wall = wallRoot
        let report = mediaReport(
            locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 3), true)],
            ownRoot: own, wallRoot: wall
        )
        let witness = mediaWitness(unopenable: 2, examined: 3)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        #expect(audit.unaccountedUnprefixed == -2)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census", offset: 30))
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("did not describe"))
    }

    /// The launch pass's own record is rendered rather than denied: "no pass has been observed this
    /// process" was false on every device whose launch pass ran and did not latch.
    @Test func aFalseLatchWithNoFundedWitnessNamesTheLaunchPass() {
        let record = MediaLaunchPassRecord(latched: false, completedAt: Self.epoch)
        let line = Phase3GateReadoutBuilder.mediaLatchLine(latch: false, witness: nil,
                                                           passInFlight: false, launchPass: record)
        #expect(line.contains("the launch pass at"))
        #expect(!line.contains("no pass has been observed"))
        #expect(Phase3GateReadoutBuilder.mediaLatchLine(latch: false, witness: nil, passInFlight: false)
            .contains("no pass has been observed"),
                "with no launch record either, the honest string is still the bare one")
    }

    /// The label-to-location mapping, asserted by LITERAL path component rather than through the
    /// very function the audit uses to name them. Every media fixture in this suite builds its URLs
    /// from `expectedURLs`, so a reordering of the two corpus layouts would keep the whole suite
    /// green while residue B was computed from the wrong file.
    @Test func theMediaLabelMappingHoldsAgainstLiteralPathComponents() {
        let own = URL(fileURLWithPath: "/tmp/phase3-label-own")
        let wall = URL(fileURLWithPath: "/tmp/phase3-label-wall")
        let expected: [(MediaCorpusLabel, [String])] = [
            (.mealPhotos, ["MealPhotos"]),
            (.recipePhotos, ["RecipePhotos"]),
            (.progressPhotos, ["ProgressPhotos", "Photos"]),
            (.progressIndex, ["ProgressPhotos", "index.bin"]),
            (.wallPhotos, ["MeshPhotos"]),
            (.wallThumbnails, ["MeshPhotoThumbnails"]),
            (.wallIndexSealed, ["MeshPhotoCache.sealed"]),
            (.wallIndexLegacyPlaintext, ["MeshPhotoCache.json"])
        ]
        let mapped = MediaCorpusLabel.expectedURLs(ownPhotoDocumentsDirectory: own,
                                                   friendWallSupportDirectory: wall)
        #expect(mapped.count == expected.count, "a count change silently yields NO labels at all")
        for (label, components) in expected {
            guard let entry = mapped.first(where: { $0.label == label }) else {
                Issue.record("no swept location mapped to \(label.rawValue)")
                continue
            }
            let tail = entry.url.pathComponents.suffix(components.count)
            #expect(Array(tail) == components, "\(label.rawValue) mapped to \(entry.url.lastPathComponent)")
        }
    }

    /// A location this vocabulary cannot name makes the whole subtraction unanswerable, rather than
    /// silently contributing zero to residue B.
    @Test func anUnnamedSweptLocationMakesTheMediaGateUnavailable() {
        let own = ownRoot
        let wall = wallRoot
        let stray = MediaAtRestFormatLocationCensus(
            url: own.appendingPathComponent("SomeNewCorpus"),
            kind: .directory, existed: true,
            tally: MediaAtRestFormatTally(v2Marked: 1)
        )
        let report = MediaAtRestFormatCensusReport(locations: [stray])
        let witness = mediaWitness(unopenable: 0, examined: 1)
        let audit = MediaResidueAudit.take(report: report, ownPhotoDocumentsDirectory: own,
                                           friendWallSupportDirectory: wall,
                                           latches: latches(), witness: witness)
        #expect(audit.locations.first?.residueVerdict == .unnamedLocation)
        let row = Phase3GateReadoutBuilder.row(forMedia: audit, latches: latches(), witness: witness,
                                               passInFlight: false, censusStamp: stamp("marker census", offset: 30))
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("cannot name"))
    }

    // MARK: - Sealed photo backup

    private func manifestProbe(
        _ readings: [SealedPhotoCorpus: SealedPhotoManifestReading],
        offset: TimeInterval = 0,
        index: Int = 1
    ) -> Phase3ManifestProbe {
        Phase3ManifestProbe(stamp: stamp("iCloud manifest probe #\(index)", offset: offset),
                            readings: readings)
    }

    private func provenAll() -> [SealedPhotoCorpus: SealedPhotoManifestReading] {
        Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, SealedPhotoManifestReading.proven(minimum: 2, entryCount: 3, unprovenEntries: 0,
                                                   generation: 4, deviceHighWater: 4))
        })
    }

    /// All three corpora proven with entries is the only shape that discharges.
    @Test func allThreeCorporaProvenWithEntriesDischarges() {
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(provenAll()),
                                               bodyProbes: [:], latch: true, environment: environment())
        #expect(row.verdict == .discharged)
    }

    /// A two-of-three fixture must NOT discharge.
    @Test func twoOfThreeCorporaProvenDoesNotDischarge() {
        var readings = provenAll()
        readings[.progress] = .noManifestReturned
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                               bodyProbes: [:], latch: true, environment: environment())
        #expect(!row.isDischarged)
    }

    /// An EMPTY manifest reads `minimumEntryHashVersion == 2` vacuously. It renders `.vacuous` — its
    /// own kind — and never `.discharged`, never `.blocked`.
    @Test func anEmptyManifestIsVacuousAndNeverDischargedOrBlocked() {
        var readings = provenAll()
        readings[.recipe] = .vacuousEmptyManifest(generation: 2, deviceHighWater: 2)
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                               bodyProbes: [:], latch: true, environment: environment())
        guard case let .vacuous(reason) = row.verdict else {
            Issue.record("expected .vacuous, got \(row.verdict)")
            return
        }
        #expect(reason.contains("no entry exists to carry a legacy digest"))
    }

    /// No manifest over a COMMITTED escrow route blocks; over a route that was never committed it is
    /// a vacuous satisfaction with its own reason — the owner's policy call, recorded rather than
    /// inferred.
    @Test func aMissingManifestBlocksOnACommittedRouteAndIsVacuousOnAnUncommittedOne() {
        let readings = Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, SealedPhotoManifestReading.noManifestReturned)
        })
        let committed = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                                     bodyProbes: [:], latch: false,
                                                     environment: environment(escrowRouteCommitted: true))
        guard case let .blocked(blockedReason) = committed.verdict else {
            Issue.record("expected .blocked, got \(committed.verdict)")
            return
        }
        #expect(blockedReason.contains("COMMITTED"))

        let probed = Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, BodyProbeReading.counted(0, truncatedAtPageCap: false))
        })
        let never = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                                 bodyProbes: probed, latch: false,
                                                 environment: environment(escrowRouteCommitted: false))
        guard case let .vacuous(vacuousReason) = never.verdict else {
            Issue.record("expected .vacuous, got \(never.verdict)")
            return
        }
        #expect(vacuousReason.contains("no route was ever committed"))
    }

    /// "Zero bodies" is what turns a missing manifest into a vacuous satisfaction, so a probe NOBODY
    /// TOOK and a probe that THREW must not fold as though the bodies had been enumerated and found
    /// absent. Both used to produce the same vacuous outcome as a genuine zero-body reading.
    @Test func anUntakenOrFailedBodyProbeNeverFoldsAsAGenuineZero() {
        let readings = Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, SealedPhotoManifestReading.noManifestReturned)
        })
        let unprobed = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                                    bodyProbes: [:], latch: false,
                                                    environment: environment(escrowRouteCommitted: false))
        guard case let .notTaken(untaken) = unprobed.verdict else {
            Issue.record("expected .notTaken for an untaken body probe, got \(unprobed.verdict)")
            return
        }
        #expect(untaken.contains("no body probe was"))

        let failed = Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, BodyProbeReading.failed("CKError (domain CKErrorDomain, code 4)"))
        })
        let threw = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                                 bodyProbes: failed, latch: false,
                                                 environment: environment(escrowRouteCommitted: false))
        guard case let .unavailable(cause) = threw.verdict else {
            Issue.record("expected .unavailable for a failed body probe, got \(threw.verdict)")
            return
        }
        #expect(cause.contains("not a zero"))
    }

    /// Bodies with no commit marker restore nothing, so a body probe that COUNTED some blocks even
    /// on an uncommitted route — and `.notProbed` is never folded as `.counted(0)`.
    @Test func bodiesWithNoManifestBlockAndNotProbedIsNotAZero() {
        let readings = Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, SealedPhotoManifestReading.noManifestReturned)
        })
        let withBodies = Phase3GateReadoutBuilder.row(
            forSealedPhoto: manifestProbe(readings),
            bodyProbes: [.meal: .counted(7, truncatedAtPageCap: false)],
            latch: false,
            environment: environment(escrowRouteCommitted: false)
        )
        guard case let .blocked(reason) = withBodies.verdict else {
            Issue.record("expected .blocked, got \(withBodies.verdict)")
            return
        }
        #expect(reason.contains("body records"))
        #expect(Phase3GateReadoutBuilder.bodyProbeLine(.notProbed) == "not probed")
        #expect(Phase3GateReadoutBuilder.bodyProbeLine(.counted(0, truncatedAtPageCap: false)).contains("0 body records"))
    }

    /// An unreadable manifest is `.unavailable` — never a zero, and never "corrupt".
    @Test func anUnreadableManifestIsUnavailableAndNeverCalledCorrupt() {
        var readings = provenAll()
        readings[.meal] = .unreadable("malformedRecord")
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                               bodyProbes: [:], latch: true, environment: environment())
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("not a zero"))
        // It must not ASSERT corruption. The row says the opposite out loud, because
        // `SealedBackupError.malformedRecord` covers several distinct causes including a TRANSIENT
        // unreadable CKAsset.
        #expect(reason.contains("never 'corrupt'"))
        #expect(!reason.lowercased().contains("is corrupt"))
        #expect(!reason.lowercased().contains("corrupted"))
    }

    /// `minimum == 1` prints NOT PROVEN, never "legacy entries found".
    @Test func aMinimumOfOnePrintsNotProvenRatherThanLegacyFound() {
        var readings = provenAll()
        readings[.meal] = .proven(minimum: 1, entryCount: 5, unprovenEntries: 5,
                                  generation: 3, deviceHighWater: 3)
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                               bodyProbes: [:], latch: true, environment: environment())
        guard case let .blocked(reason) = row.verdict else {
            Issue.record("expected .blocked, got \(row.verdict)")
            return
        }
        #expect(reason.contains("NOT PROVEN"))
        #expect(!reason.lowercased().contains("legacy entries found"))
        let line = Phase3GateReadoutBuilder.sealedPhotoReadingLine(readings[.meal])
        #expect(line.contains("NOT PROVEN"))
    }

    /// A generation that disagrees with this device's high-water mark is called out explicitly.
    @Test func aGenerationDisagreementIsPrintedRatherThanImplied() {
        let line = Phase3GateReadoutBuilder.sealedPhotoReadingLine(
            .proven(minimum: 2, entryCount: 1, unprovenEntries: 0, generation: 3, deviceHighWater: 7)
        )
        #expect(line.contains("DISAGREE"))
    }

    /// The permanent CloudKit-database caveat rides EVERY sealed-photo row: a Debug build reads the
    /// Development database, so a TestFlight build's manifests read here as absent — a false gate
    /// failure, never a pass.
    @Test func everySealedPhotoRowCarriesTheCloudKitDatabaseCaveat() {
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(provenAll()),
                                               bodyProbes: [:], latch: true, environment: environment())
        #expect(row.caveats.contains { $0.contains("DEVELOPMENT CloudKit database") })
    }

    /// A manifest whose record generation sits BELOW this device's high-water mark cannot be shown
    /// to be the live manifest — `SealedPhotoBackupService.restore` would refuse that same record
    /// with `.staleGeneration`. It used to discharge, with the disagreement surviving only as a
    /// bracketed suffix inside one evidence line.
    @Test func aManifestBehindTheDeviceHighWaterIsUnavailableRatherThanDischarged() {
        var readings = provenAll()
        readings[.progress] = .proven(minimum: 2, entryCount: 40, unprovenEntries: 0,
                                      generation: 3, deviceHighWater: 7)
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                               bodyProbes: [:], latch: true, environment: environment())
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("BELOW"))
        #expect(reason.contains("staleGeneration"))
        #expect(!row.isDischarged)
        #expect(row.caveats.contains { $0.contains("STALE MANIFEST") },
                "a disagreement must be a row caveat, not only a suffix in one evidence line")
    }

    /// The ordinary direction — another device wrote a manifest this one has not consumed — still
    /// discharges. The clause must not over-block.
    @Test func aManifestAheadOfTheDeviceHighWaterStillDischarges() {
        var readings = provenAll()
        readings[.progress] = .proven(minimum: 2, entryCount: 40, unprovenEntries: 0,
                                      generation: 9, deviceHighWater: 7)
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(readings),
                                               bodyProbes: [:], latch: true, environment: environment())
        #expect(row.verdict == .discharged)
    }

    /// A sitting taken with `FERNLET_SKIP_SEALED_RESTORE=1` cannot discharge this gate at all: that
    /// guard fronts the UPLOAD path, so the full-verification pass the gate's wording requires
    /// silently no-ops, whatever the manifests already in the cloud read.
    @Test func theSkipSealedRestoreGuardInvalidatesTheSealedPhotoGate() {
        let invalid = Phase3GateEnvironment(
            sealedBackupOwnPhotosEnabled: true, escrowRouteCommitted: true,
            skipSealedRestoreEnvSet: true, lockConfigured: true, privateHubUnlocked: false,
            duressSessionActive: false, ownPhotoBackupPassInFlight: false,
            lastFullPassCompletedAt: nil, hasEmbeddedProvisioningProfile: false,
            systemVersion: "iOS 26.0", deviceModel: "iPhone17,1"
        )
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(provenAll()),
                                               bodyProbes: [:], latch: true, environment: invalid)
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("FERNLET_SKIP_SEALED_RESTORE"))
    }

    /// The coordinator's retained per-corpus verdicts are RENDERED, under a heading that says what
    /// they are not. `examined` is the "never looked / examined-none" fact a live probe cannot
    /// produce, and it was retained, tested and shown to nobody.
    @Test func theFullPassVerdictsAreRenderedAsALabelledByProduct() {
        let verdicts = [
            SealedPhotoCorpusFormatVerdict(corpus: .meal, committed: true, examined: true,
                                           observedMinima: [1, 2], unreadable: 0, healedEntries: 4)
        ]
        let row = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(provenAll()),
                                               bodyProbes: [:], latch: true, environment: environment(),
                                               fullPassVerdicts: verdicts)
        #expect(row.evidence.contains { $0.contains("BY-PRODUCT of a writing pass, not the gate") })
        #expect(row.evidence.contains { $0.contains("examined true") && $0.contains("healedEntries 4") })
        let none = Phase3GateReadoutBuilder.row(forSealedPhoto: manifestProbe(provenAll()),
                                                bodyProbes: [:], latch: true, environment: environment())
        #expect(none.evidence.contains { $0.contains("none retained this process") },
                "an absent by-product says so rather than being omitted")
    }

    // MARK: - Lock wrap

    private func lockReport(_ state: LockWrapFormatState) -> LockWrapFormatCensusReport {
        LockWrapFormatCensusReport(
            keychainService: "com.fernlet.lock.test.phase3",
            account: LockWrapFormatCensus.account,
            state: state
        )
    }

    /// `.absent` with NO lock configured is a named earned zero, and it discharges.
    @Test func anAbsentWrapWithNoLockConfiguredDischargesAsAnEarnedZero() {
        let row = Phase3GateReadoutBuilder.row(forLockWrap: lockReport(.absent), rowLatch: true,
                                               lockConfigured: false, stamp: stamp("marker census"))
        #expect(row.verdict == .discharged)
    }

    /// `.absent` with a lock CONFIGURED does NOT discharge, and the row names the two remaining
    /// honest absences.
    @Test func anAbsentWrapWithALockConfiguredDoesNotDischargeAndNamesBothAbsences() {
        let row = Phase3GateReadoutBuilder.row(forLockWrap: lockReport(.absent), rowLatch: true,
                                               lockConfigured: true, stamp: stamp("marker census"))
        guard case let .notTaken(reason) = row.verdict else {
            Issue.record("expected .notTaken, got \(row.verdict)")
            return
        }
        #expect(reason.contains("enclave-bound"))
        #expect(reason.contains("gone missing"))
    }

    /// `.malformedEmpty` and `.unreadable` are `.unavailable`, never zeros.
    @Test func aMalformedOrUnreadableWrapIsUnavailableRatherThanAZero() {
        let empty = Phase3GateReadoutBuilder.row(forLockWrap: lockReport(.malformedEmpty), rowLatch: false,
                                                 lockConfigured: true, stamp: nil)
        guard case .unavailable = empty.verdict else {
            Issue.record("expected .unavailable for malformedEmpty, got \(empty.verdict)")
            return
        }
        let unreadable = Phase3GateReadoutBuilder.row(
            forLockWrap: lockReport(.unreadable(errSecInteractionNotAllowed)),
            rowLatch: false, lockConfigured: true, stamp: nil
        )
        guard case let .unavailable(reason) = unreadable.verdict else {
            Issue.record("expected .unavailable for unreadable, got \(unreadable.verdict)")
            return
        }
        #expect(reason.contains("not a zero"))
    }

    /// The derived row latch is rendered but explicitly licenses nothing, and a disagreement with the
    /// census row it re-reads is called out.
    @Test func theDerivedRowLatchIsLabelledNonEvidenceAndADisagreementIsNamed() {
        let row = Phase3GateReadoutBuilder.row(forLockWrap: lockReport(.v2Marked), rowLatch: false,
                                               lockConfigured: true, stamp: nil)
        #expect(row.witnesses.contains(.derivedRowLatch))
        #expect(row.caveats.contains { $0.contains("licenses NOTHING") })
        #expect(row.caveats.contains { $0.contains("DISAGREE") })
    }

    // MARK: - Heart-drop sidecars

    private func sidecarReport(
        _ states: [HeartDropSidecarFormatCensus.Sidecar: HeartDropSidecarFormatCensus.FileState]
    ) -> HeartDropSidecarFormatCensus.Report {
        HeartDropSidecarFormatCensus.Report(
            directory: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/x/Library/Proximity"),
            files: HeartDropSidecarFormatCensus.Sidecar.allCases.map { sidecar in
                HeartDropSidecarFormatCensus.FileReading(
                    sidecar: sidecar,
                    fileName: sidecar.url(in: URL(fileURLWithPath: "/tmp")).lastPathComponent,
                    state: states[sidecar] ?? .absent
                )
            }
        )
    }

    /// A LEGACY quarantine sidecar with three clean main rows DISCHARGES. The quarantine is excluded
    /// from the gate because no reader ever opens that path, and folding it into an aggregate would
    /// strand the gate forever on bytes whose format cannot matter.
    @Test func aLegacyQuarantineWithCleanMainRowsDischarges() {
        let report = sidecarReport([
            .outbox: .v2Sealed, .peerBundles: .absent, .dedup: .empty, .outboxQuarantine: .legacySealed
        ])
        #expect(report.legacySealedCount == 1, "the aggregate INCLUDES the quarantine, which is why it is not the gate")
        let row = Phase3GateReadoutBuilder.row(forHeartDrop: report, latch: true, stamp: nil)
        #expect(row.verdict == .discharged)
        #expect(row.caveats.contains { $0.contains("EXCLUDED") })
    }

    /// A legacy OUTBOX blocks even with a clean quarantine.
    @Test func aLegacyOutboxBlocksEvenWithACleanQuarantine() {
        let report = sidecarReport([
            .outbox: .legacySealed, .peerBundles: .v2Sealed, .dedup: .v2Sealed, .outboxQuarantine: .absent
        ])
        let row = Phase3GateReadoutBuilder.row(forHeartDrop: report, latch: false, stamp: nil)
        guard case let .blocked(reason) = row.verdict else {
            Issue.record("expected .blocked, got \(row.verdict)")
            return
        }
        #expect(reason.contains("outbox"))
    }

    /// An unreadable dedup row is `.unavailable`, never a zero.
    @Test func anUnreadableDedupRowIsUnavailable() {
        let report = sidecarReport([
            .outbox: .v2Sealed, .peerBundles: .v2Sealed, .dedup: .unreadable, .outboxQuarantine: .absent
        ])
        let row = Phase3GateReadoutBuilder.row(forHeartDrop: report, latch: false, stamp: nil)
        guard case let .unavailable(reason) = row.verdict else {
            Issue.record("expected .unavailable, got \(row.verdict)")
            return
        }
        #expect(reason.contains("dedup"))
    }

    // MARK: - Pending narrative buffer

    /// `.absent` is an EARNED zero here and discharges; `.unreadable` is `.unavailable`.
    @Test func theBufferGateDischargesOnAnEarnedAbsenceAndRefusesAnUnreadableOne() {
        let absent = Phase3GateReadoutBuilder.row(
            forPendingNarrative: PendingNarrativeBufferFormatCensus(
                format: .absent,
                fileURL: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/x/Library/PendingNarratives.bin")
            ),
            stamp: nil
        )
        #expect(absent.verdict == .discharged)

        let unreadable = Phase3GateReadoutBuilder.row(
            forPendingNarrative: PendingNarrativeBufferFormatCensus(
                format: .unreadable(reason: "Operation not permitted"),
                fileURL: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/x/Library/PendingNarratives.bin")
            ),
            stamp: nil
        )
        guard case let .unavailable(reason) = unreadable.verdict else {
            Issue.record("expected .unavailable, got \(unreadable.verdict)")
            return
        }
        #expect(reason.contains("not a zero"))
    }

    // MARK: - Structure

    private func inputs(
        census: CryptoFormatCensus.Readings?,
        latches: Phase3LatchReadings?,
        own: URL,
        wall: URL
    ) -> Phase3GateReadoutInputs {
        Phase3GateReadoutInputs(
            environment: environment(),
            ownPhotoDocumentsDirectory: own,
            friendWallSupportDirectory: wall,
            census: census,
            censusStamp: census == nil ? nil : stamp("marker census"),
            latches: latches,
            latchStamp: latches == nil ? nil : stamp("completion latches")
        )
    }

    private func cleanReadings(own: URL, wall: URL) -> CryptoFormatCensus.Readings {
        CryptoFormatCensus.Readings(
            sealedColumns: .counted(cleanColumnCensus()),
            pendingNarrative: PendingNarrativeBufferFormatCensus(
                format: .absent,
                fileURL: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/x/Library/PendingNarratives.bin")
            ),
            media: mediaReport(
                locations: [(.mealPhotos, MediaAtRestFormatTally(v2Marked: 2), true)],
                ownRoot: own, wallRoot: wall
            ),
            lockWrap: lockReport(.v2Marked),
            heartDrop: sidecarReport([.outbox: .v2Sealed, .peerBundles: .absent, .dedup: .v2Sealed])
        )
    }

    /// Exactly one row per gate, in `allCases` order, and every row names at least one witness kind.
    @Test func theReadoutCarriesExactlyOneRowPerGateInOrder() {
        let own = ownRoot
        let wall = wallRoot
        let readout = Phase3GateReadoutBuilder.readout(from: inputs(
            census: cleanReadings(own: own, wall: wall), latches: latches(), own: own, wall: wall
        ))
        #expect(readout.rows.map(\.gate) == Phase3Gate.allCases)
        #expect(readout.allGatesReported)
        #expect(readout.rows.allSatisfy { !$0.witnesses.isEmpty })
    }

    /// Before the local scan lands, EVERY gate says so. An unread latch is not a cleared latch, and
    /// folding an all-false reading as evidence is the one thing this instrument must never do.
    @Test func beforeTheScanLandsEveryGateIsNotTakenRatherThanFoldingAnAllFalseLatch() {
        let own = ownRoot
        let wall = wallRoot
        let readout = Phase3GateReadoutBuilder.readout(from: inputs(
            census: nil, latches: nil, own: own, wall: wall
        ))
        #expect(readout.rows.count == Phase3Gate.allCases.count)
        for row in readout.rows {
            guard case let .notTaken(reason) = row.verdict else {
                Issue.record("\(row.gate.rawValue) must be .notTaken before the scan, got \(row.verdict)")
                continue
            }
            #expect(reason.contains("not a cleared latch"))
        }
        #expect(readout.stamps.isEmpty)
    }

    /// `Phase3LatchReadings.take(inputs:defaults:)` reads all seven bits from an ISOLATED suite,
    /// taking its keychain service from the injected `Inputs` rather than a re-spelled constant.
    @Test func latchReadingsTakeAllSevenBitsFromAnInjectedSuiteAndService() throws {
        let suiteName = "fernlet.tests.phase3.latches.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: MediaAtRestFormatMigrationLatch.defaultsKey)
        let service = "com.fernlet.lock.test.phase3.\(UUID().uuidString)"
        // An IN-MEMORY controller, never `.shared`: `take(inputs:defaults:)` reads only
        // `lockKeychainService` off the inputs, and a test must never be the thing that creates the
        // process-wide sealed store (the `PhotoDirectoryIsolationTests` hazard).
        let censusInputs = CryptoFormatCensus.Inputs(
            sealedStore: PrivatePersistenceController(inMemory: true),
            ownPhotoDocumentsDirectory: URL(fileURLWithPath: "/tmp/phase3-own"),
            friendWallSupportDirectory: URL(fileURLWithPath: "/tmp/phase3-wall"),
            narrativeScope: .production,
            lockKeychainService: service,
            heartDropDirectory: URL(fileURLWithPath: "/tmp/phase3-heart")
        )
        let readings = Phase3LatchReadings.take(inputs: censusInputs, defaults: defaults)
        #expect(readings.mediaAtRest, "the media latch must be read from the injected suite")
        #expect(!readings.sealedColumn)
        #expect(!readings.ownPhotoKey)
        #expect(!readings.heartDropSidecar)
        #expect(!readings.sealedPhotoBackup)
        // An empty keychain service reads as an ABSENT wrap row, which the derived latch calls
        // complete — which is exactly why the row copy says it licenses nothing.
        #expect(readings.lockWrapRow)
        #expect(readings.printedLines.count == 6)
    }

    // MARK: - The redaction wall

    /// The export promise, enforced rather than promised — on BOTH egress routes, so the log route
    /// cannot become the leak the pasteboard route is tested against.
    ///
    /// The fixtures deliberately DO carry `<uuid>.jpg` names and `/var/mobile/Containers/...` paths.
    @Test func neitherExportRouteEmitsAUUIDAPathOrAFileName() throws {
        let own = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Documents")
        let wall = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Library/Proximity")
        let readout = Phase3GateReadoutBuilder.readout(from: Phase3GateReadoutInputs(
            environment: environment(),
            ownPhotoDocumentsDirectory: own,
            friendWallSupportDirectory: wall,
            census: cleanReadings(own: own, wall: wall),
            censusStamp: stamp("marker census"),
            latches: latches(),
            latchStamp: stamp("completion latches"),
            preResetLatchSnapshot: latches(),
            manifestProbes: [manifestProbe(provenAll()), manifestProbe(dirtyErrorReadings(), offset: 5)],
            bodyProbes: [.meal: .failed(Phase3ProbeFailure.summarize(Self.dirtyError))],
            mediaWitness: mediaWitness(unopenable: 0, examined: 2, offset: 10),
            sealedColumnWitness: keyedWitness(offset: -10),
            refusals: ["Fetch manifests refused: an own-photo pass was in flight."]
        ))
        let text = Phase3GateReportBuilder.text(for: readout)
        let chunks = Phase3GateReportBuilder.chunks(for: readout, maxBytes: 1_024)
        #expect(!chunks.isEmpty)
        for payload in [text] + chunks {
            try assertRedacted(payload)
        }
        #expect(chunks.joined(separator: "\n") == text, "the chunks must reassemble into the report")
        // A blank separator line landing at a chunk boundary must survive the round trip: a string
        // accumulator would silently drop it, and the reassembly assertion above is what catches it.
        #expect(text.contains("\n\nTRAILER"))
    }

    /// A `CKError`-shaped error whose `userInfo` deliberately carries the two payloads the report's
    /// contract forbids: a sealed-photo record name built from a photo UUID, and a container path.
    private static let dirtyError = NSError(domain: "CKErrorDomain", code: 11, userInfo: [
        NSLocalizedDescriptionKey: "record sealed-photo.progress.\(UUID().uuidString) not found",
        "CKPartialErrors": "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Library/Caches/x.jpg"
    ])

    private func dirtyErrorReadings() -> [SealedPhotoCorpus: SealedPhotoManifestReading] {
        Dictionary(uniqueKeysWithValues: SealedPhotoCorpus.allCases.map {
            ($0, SealedPhotoManifestReading.unreadable(Phase3ProbeFailure.summarize(Self.dirtyError)))
        })
    }

    /// The two free-text payloads are the ENTIRE attack surface of the redaction contract — every
    /// other string in the report is composed from counts and frozen tokens — and they were the two
    /// the fixture never exercised. The protection is at the capture site, so this pins the
    /// classifier directly as well as end to end.
    @Test func aCaughtErrorIsReducedToADomainAndCodeBeforeItCanBeRetained() throws {
        let summary = Phase3ProbeFailure.summarize(Self.dirtyError)
        #expect(summary.contains("CKErrorDomain"))
        #expect(summary.contains("code 11"))
        try assertRedacted(summary)
        #expect(!summary.contains("not found"), "no localizedDescription, which can quote a record")
    }

    private func assertRedacted(_ payload: String) throws {
        #expect(!payload.contains("/var/"), "a filesystem path reached the report")
        #expect(!payload.contains("/Containers/"), "a container path reached the report")
        #expect(!payload.contains(".jpg"), "a media file name reached the report")
        let uuid = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        #expect(uuid.firstMatch(in: payload, range: range) == nil, "a UUID-shaped substring reached the report")
        let base64Hash = try NSRegularExpression(pattern: "[A-Za-z0-9+/]{40,}={0,2}")
        #expect(base64Hash.firstMatch(in: payload, range: range) == nil,
                "a base64-shaped content hash reached the report")
    }

    // MARK: - Export completeness

    /// The trailer names EVERY non-discharged row grouped by verdict KIND, and leads with the count.
    /// A trailer listing only the not-taken ones would let a skimmed report read as complete while a
    /// row that answered BLOCKING appeared only in the body.
    @Test func theTrailerNamesEveryNonDischargedRowGroupedByKind() {
        let rows = [
            Phase3GateRow(gate: .sealedColumns, witnesses: [.markerCensus], stamps: [],
                          verdict: .blocked("a bucket"), evidence: [], caveats: []),
            Phase3GateRow(gate: .pendingNarrativeBuffer, witnesses: [.markerCensus], stamps: [],
                          verdict: .vacuous("nothing to be about"), evidence: [], caveats: []),
            Phase3GateRow(gate: .mediaAtRest, witnesses: [.markerCensus], stamps: [],
                          verdict: .notTaken("nobody asked"), evidence: [], caveats: []),
            Phase3GateRow(gate: .lockContentKeyWrap, witnesses: [.markerCensus], stamps: [],
                          verdict: .unavailable("could not answer"), evidence: [], caveats: []),
            Phase3GateRow(gate: .heartDropSidecars, witnesses: [.markerCensus], stamps: [],
                          verdict: .discharged, evidence: [], caveats: []),
            Phase3GateRow(gate: .sealedPhotoBackup, witnesses: [.manifestProbe], stamps: [],
                          verdict: .discharged, evidence: [], caveats: [])
        ]
        let readout = Phase3GateReadout(
            stamps: [], environment: environment(), rows: rows, preResetLatchSnapshot: nil,
            checklist: [], refusals: [], mediaAudit: nil, manifestProbes: []
        )
        #expect(readout.rowsNotDischarged.map(\.kind) == ["BLOCKED", "UNAVAILABLE", "VACUOUS", "NOT TAKEN"])
        let text = Phase3GateReportBuilder.text(for: readout)
        #expect(text.contains("2 of 6 gates discharged; 4 did not"))
        #expect(text.contains("a bucket"))
        #expect(text.contains("nothing to be about"))
        #expect(text.contains("could not answer"))
        #expect(text.contains("nobody asked"))
    }

    /// The report prints EVERY stamp in acquisition order — there is deliberately no single
    /// `takenAt`, so a reader months later can see which observation predates which.
    @Test func theReportPrintsEveryStampInAcquisitionOrder() {
        let own = ownRoot
        let wall = wallRoot
        let readout = Phase3GateReadoutBuilder.readout(from: Phase3GateReadoutInputs(
            environment: environment(),
            ownPhotoDocumentsDirectory: own,
            friendWallSupportDirectory: wall,
            census: cleanReadings(own: own, wall: wall),
            censusStamp: stamp("marker census", offset: 100),
            latches: latches(),
            latchStamp: stamp("completion latches", offset: 100),
            mediaWitness: mediaWitness(unopenable: 0, examined: 2, offset: 50),
            sealedColumnWitness: keyedWitness(offset: 0)
        ))
        #expect(readout.stamps.map(\.takenAt) == readout.stamps.map(\.takenAt).sorted())
        let text = Phase3GateReportBuilder.text(for: readout)
        for stamp in readout.stamps {
            #expect(text.contains(stamp.printed))
        }
    }

    /// EVERY probe reaches the report, not just the one the gate row folds.
    ///
    /// The sitting takes probe #1 before Privacy & Data → Retry precisely because Retry forces
    /// generation and deviceHighWater into agreement, so probe #2 structurally cannot show the
    /// disagreement probe #1 exists to capture. Printing only the last carried the stamps of two
    /// readings and the numbers of one — and the missing one is the unrepeatable one.
    @Test func everyManifestProbeReachesTheReportNotJustTheLast() {
        let own = ownRoot
        let wall = wallRoot
        var stale = provenAll()
        stale[.meal] = .proven(minimum: 1, entryCount: 12, unprovenEntries: 12,
                               generation: 7, deviceHighWater: 9)
        let readout = Phase3GateReadoutBuilder.readout(from: Phase3GateReadoutInputs(
            environment: environment(),
            ownPhotoDocumentsDirectory: own,
            friendWallSupportDirectory: wall,
            census: cleanReadings(own: own, wall: wall),
            censusStamp: stamp("marker census"),
            latches: latches(),
            latchStamp: stamp("completion latches"),
            manifestProbes: [manifestProbe(stale, offset: 0, index: 1),
                             manifestProbe(provenAll(), offset: 60, index: 2)]
        ))
        let text = Phase3GateReportBuilder.text(for: readout)
        #expect(text.contains("MANIFEST PROBES, IN ORDER"))
        #expect(text.contains("iCloud manifest probe #1"))
        #expect(text.contains("iCloud manifest probe #2"))
        #expect(text.contains("deviceHighWater 9"), "probe #1's unrepeatable disagreement must print")
        #expect(text.contains("NOT PROVEN"), "probe #1's pre-Retry minimum must print")
    }

    /// A reset taken before the scan landed says so in the export, rather than omitting the section
    /// the confirmation dialog promised to fill.
    @Test func aResetWithNoPreResetSnapshotSaysSoRatherThanOmittingTheSection() {
        let readout = Phase3GateReadout(
            stamps: [], environment: environment(), rows: [],
            preResetLatchSnapshot: nil,
            sealedColumnResetTakenAt: Self.epoch,
            checklist: [], refusals: [], mediaAudit: nil, manifestProbes: []
        )
        let text = Phase3GateReportBuilder.text(for: readout)
        #expect(text.contains("NOT CAPTURED"))
        #expect(text.contains("LATCHES AS THEY READ BEFORE THE RESET"))
    }

    /// The report's header states the one-launch rule: nothing here is persisted, and probe #1
    /// cannot be re-taken after Retry.
    @Test func theReportHeaderStatesTheSittingLivesInOneAppLaunch() {
        let readout = Phase3GateReadout(
            stamps: [], environment: environment(), rows: [], preResetLatchSnapshot: nil,
            checklist: [], refusals: [], mediaAudit: nil, manifestProbes: []
        )
        #expect(Phase3GateReportBuilder.text(for: readout).contains("ONE app launch"))
    }

    /// Every log chunk stays under os_log's ~1 024-byte message ceiling, so a chunk cannot arrive
    /// half-length while its index says it arrived — the one truncation the i/n scheme cannot see.
    @Test func everyLogChunkFitsUnderTheUnifiedLogsMessageCeiling() {
        let own = ownRoot
        let wall = wallRoot
        let readout = Phase3GateReadoutBuilder.readout(from: Phase3GateReadoutInputs(
            environment: environment(),
            ownPhotoDocumentsDirectory: own,
            friendWallSupportDirectory: wall,
            census: cleanReadings(own: own, wall: wall),
            censusStamp: stamp("marker census"),
            latches: latches(),
            latchStamp: stamp("completion latches"),
            manifestProbes: [manifestProbe(provenAll())]
        ))
        let chunks = Phase3GateReportBuilder.chunks(for: readout, maxBytes: 768)
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            // A single line longer than the bound travels whole by design; the cap is on the JOIN.
            let longest = chunk.split(separator: "\n", omittingEmptySubsequences: false)
                .map(\.utf8.count).max() ?? 0
            #expect(chunk.utf8.count <= max(768, longest),
                    "a chunk of \(chunk.utf8.count) bytes would be truncated by the unified log")
        }
        #expect(chunks.joined(separator: "\n") == Phase3GateReportBuilder.text(for: readout))
    }

    /// Duress is enforced in the PURE layer, not only by the view's `if`.
    ///
    /// The model already carried the flag and read it nowhere: a refactor of the view's
    /// `@ViewBuilder` would have let the fold and both export routes assemble real per-corpus photo
    /// counts and real decrypted manifest minima under a decoy session, with the suite green.
    @Test func aDuressSessionFoldsToSixRefusalsAndCarriesNoReadingIntoTheExport() {
        let own = ownRoot
        let wall = wallRoot
        let duress = Phase3GateEnvironment(
            sealedBackupOwnPhotosEnabled: true, escrowRouteCommitted: true,
            skipSealedRestoreEnvSet: false, lockConfigured: true, privateHubUnlocked: true,
            duressSessionActive: true, ownPhotoBackupPassInFlight: false,
            lastFullPassCompletedAt: nil, hasEmbeddedProvisioningProfile: false,
            systemVersion: "iOS 26.0", deviceModel: "iPhone17,1"
        )
        let readout = Phase3GateReadoutBuilder.readout(from: Phase3GateReadoutInputs(
            environment: duress,
            ownPhotoDocumentsDirectory: own,
            friendWallSupportDirectory: wall,
            census: cleanReadings(own: own, wall: wall),
            censusStamp: stamp("marker census"),
            latches: latches(),
            latchStamp: stamp("completion latches"),
            manifestProbes: [manifestProbe(provenAll())],
            bodyProbes: [.meal: .counted(412, truncatedAtPageCap: false)],
            mediaWitness: mediaWitness(unopenable: 0, examined: 2),
            sealedColumnWitness: keyedWitness()
        ))
        #expect(readout.rows.allSatisfy { !$0.isDischarged })
        #expect(readout.stamps.isEmpty)
        #expect(readout.manifestProbes.isEmpty)
        #expect(readout.mediaAudit == nil)
        let text = Phase3GateReportBuilder.text(for: readout)
        #expect(text.contains("duress session is active"))
        #expect(!text.contains("412"), "no per-corpus count may reach either export route")
    }
}
