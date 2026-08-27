// HeartDropSidecarFormatCensusTests.swift
// FernletTests
//
// Phase 0 of Docs/Plan-Crypto-Standardization-2026-08-27.md: the read-only marker-bytes census of
// the heart-drop sidecar corpus (`HeartDropSidecarFormatCensus`).
//
// What these tests have to establish, because Phase 3 deletes the legacy reader on the strength of
// the number this census produces:
//   1. A byte-exact `FSC1` blob is counted as legacy. This suite plants the FIRST such fixture the
//      repo has ever had — the legacy-read branch at `HeartDropSidecarKey.swift:59-61` shipped
//      untested — and proves the fixture is genuine by opening it through the real seal.
//   2. What PRODUCTION writes is counted as v2. The `FSC2` case is not planted: an actual
//      `HeartDropOutbox` on an isolated scope seals an actual entry, so the census is measured
//      against the writer it exists to audit.
//   3. Classification never needs the key — proven by wiping the seal key and re-censusing.
//   4. Everything the census cannot vouch for lands in a bucket that keeps `isClean` false.
//   5. The census WRITES NOTHING: byte-identical files across a pass, and an empty (or absent)
//      directory is left exactly as it was found.
//
// Isolation: `uniqueProximityDirectory()` + `uniqueHeartDropKeychainService()` per test (the
// house rule for anything heart-drop — a shared directory or a shared keychain service lets a
// concurrent wipe delete this suite's fixtures out from under it).

import Foundation
import Testing
import CryptoKit
import Security
import ProximityKit
import FernletFoundation

@MainActor
struct HeartDropSidecarFormatCensusTests {

    // MARK: - Harness

    /// A fresh, created-on-disk heart-drop root. Created here (unlike the helper's contract of
    /// leaving nothing behind) because several tests plant files into it directly.
    private func makeRoot() throws -> URL {
        let root = uniqueProximityDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A byte-exact `FSC1` legacy sidecar blob: the legacy magic, then a ChaCha20-Poly1305 box
    /// sealed with NO authenticated data — which is precisely why the format could not be
    /// relabelled in place and had to become a read-only rung (`HeartDropSidecarKey.swift:32-33`).
    /// The layout mirrors the current writer exactly, minus the domain binding: prefix + combined
    /// box (`HeartDropSidecarKey.swift:66-78`).
    private func legacyBlob(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        // cryptographic-domain: legacy-read — this fixture reproduces the pre-91c3956 unbound box
        // on purpose; it is the only way to exercise the legacy branch this round plans to delete.
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return Data("FSC1".utf8) + box.combined
    }

    /// Mints a 32-byte seal key and files it where `HeartDropSidecarSeal` looks for it, so a
    /// planted legacy blob can be opened through the real seal. Returns the key for building the
    /// fixture. The account literal matches `HeartDropSidecarKey.swift:31` (same literal
    /// `HeartDropTests` uses to assert the wipe took the key).
    private func plantSealKey(service: String) -> SymmetricKey {
        let keyData = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let status = KeychainItem.store(
            keyData,
            account: "sidecarSealKey",
            service: service,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false
        )
        #expect(status == errSecSuccess, "the fixture seal key was not filed in the keychain")
        return SymmetricKey(data: keyData)
    }

    /// Drives a REAL `HeartDropOutbox` on this root + service until it has sealed one entry, and
    /// returns the file it wrote. Nothing here is planted: these are the bytes production emits.
    private func mintProductionOutboxFile(root: URL, service: String) -> URL {
        let url = HeartDropOutbox.fileURL(in: root)
        let outbox = HeartDropOutbox(
            fileURL: url,
            seal: HeartDropSidecarSeal.make(keychainService: service)
        )
        let entry = HeartDropOutbox.Entry(
            id: UUID(),
            friendSigningKey: Data(repeating: 0x11, count: 32),
            tag: "fixture-tag",
            wire: Data(repeating: 0x22, count: 48),
            createdAt: Date()
        )
        #expect(outbox.enqueue(entry) == .queued, "the fixture outbox never durably sealed anything")
        return url
    }

    /// Every file currently in `root`, by name, with its bytes — the read-only proof's snapshot.
    private func snapshot(_ root: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var bytes: [String: Data] = [:]
        for name in names {
            bytes[name] = try Data(contentsOf: root.appendingPathComponent(name))
        }
        return bytes
    }

    private func plant(_ bytes: Data, as sidecar: HeartDropSidecarFormatCensus.Sidecar, in root: URL) throws {
        try bytes.write(to: sidecar.url(in: root), options: [.atomic])
    }

    // MARK: - The corpus table

    /// The four names the census reads, pinned as LITERALS. The table itself derives its names from
    /// the stores (so it cannot drift from what they write) — which is exactly why the literals need
    /// pinning somewhere: renaming a store's file would silently move the census with it and leave
    /// the old on-disk file uncounted, i.e. a legacy blob that never appears in the number Phase 3
    /// is gated on. A rename must therefore break this test and be a deliberate decision.
    @Test func theCorpusIsExactlyTheFourKnownFileNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let names = HeartDropSidecarFormatCensus.survey(in: root).files.map(\.fileName)
        #expect(names == [
            "HeartDropOutbox.json",
            "HeartDropPeerBundles.json",
            "HeartDropDedup.json",
            "HeartDropOutbox.json.corrupt"
        ])
        #expect(HeartDropSidecarFormatCensus.markerByteCount == 4, "both markers are 4 ASCII bytes")
    }

    // MARK: - Legacy (FSC1)

    /// The first `FSC1` fixture in the repo, counted as legacy. This is THE number Phase 3 waits to
    /// see reach zero, so a census that failed to recognise the legacy prefix would authorise
    /// deleting a reader while readable-only-by-it bytes were still on disk.
    @Test func aByteExactLegacyBlobIsCountedAsLegacySealed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let blob = try legacyBlob(Data("[]".utf8), key: SymmetricKey(size: .bits256))
        try plant(blob, as: .dedup, in: root)

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.state(of: .dedup) == .legacySealed)
        #expect(report.legacySealedCount == 1)
        #expect(report.v2SealedCount == 0)
        #expect(report.isConclusive)
        #expect(!report.isClean, "a scope holding a legacy blob is not proof of completion")
    }

    /// The fixture is a GENUINE legacy blob, not just four convincing bytes: the shipping seal —
    /// the one whose legacy branch Phase 3 deletes — opens it back to the original plaintext.
    /// Without this, the census test above could pass against a fixture no real device ever wrote.
    @Test func theLegacyFixtureOpensThroughTheShippingLegacyBranch() throws {
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }

        let key = plantSealKey(service: service)
        let plaintext = Data(#"[{"note":"legacy"}]"#.utf8)
        let blob = try legacyBlob(plaintext, key: key)

        let seal = HeartDropSidecarSeal.make(keychainService: service)
        #expect(seal.isSealed(blob), "the shipping seal does not recognise its own legacy prefix")
        #expect(try seal.open(blob) == plaintext)
    }

    // MARK: - Current (FSC2), as production writes it

    /// The census is measured against the real writer: an actual outbox seals an actual entry, and
    /// those bytes must classify as v2. The raw-prefix assertion mirrors
    /// `HeartDropTests.sealedSidecarsRoundTripAndWipeRemovesTheKey` — the literal is deliberate.
    @Test func bytesWrittenByTheRealOutboxAreCountedAsV2Sealed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }

        let url = mintProductionOutboxFile(root: root, service: service)
        #expect(try Data(contentsOf: url).starts(with: Data("FSC2".utf8)))

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.state(of: .outbox) == .v2Sealed)
        #expect(report.v2SealedCount == 1)
        #expect(report.legacySealedCount == 0)
        #expect(report.absentCount == 3, "the other three files were never written")
        #expect(report.isClean, "a fully-migrated scope must read clean")
    }

    /// Classification is key-free, and this is the case that proves it matters: the seal key is
    /// deleted (a delete-all, or simply another scope's wipe) and the ciphertext still counts as
    /// v2. A census that reached for the key would report nothing here — an encouraging zero on
    /// exactly the device whose bytes are least recoverable.
    @Test func classificationSurvivesTheSealKeyBeingWiped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }

        _ = mintProductionOutboxFile(root: root, service: service)
        KeychainItem.deleteAll(service: service)
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service) == nil)

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.state(of: .outbox) == .v2Sealed)
        #expect(report.isConclusive)
    }

    // MARK: - The conflated bucket, empty, and absent

    /// A v0 plaintext sidecar (the shape that predates the seal entirely) and outright garbage are
    /// indistinguishable by marker bytes, and the census says so instead of decoding the JSON to
    /// find out — decoding would read the user's friend graph. Both land in the one honest bucket;
    /// `ProtectedSidecar.performLoad` is the runtime authority that separates them.
    @Test func plaintextV0AndGarbageShareTheConflatedBucket() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try plant(Data("[]".utf8), as: .outbox, in: root)
        try plant(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]), as: .dedup, in: root)

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.state(of: .outbox) == .unsealedOrUnrecognized)
        #expect(report.state(of: .dedup) == .unsealedOrUnrecognized)
        #expect(report.unsealedOrUnrecognizedCount == 2)
        #expect(!report.isClean, "unrecognised bytes are unproven, never clean")
    }

    /// Near misses are not sealed. A prefix that merely looks like the marker family — a future
    /// `FSC3`, or a truncated `FSC` — must never be counted as migrated, and a truncated head
    /// shorter than the marker cannot match either constant.
    @Test func nearMissMarkersAreNeverCountedAsSealed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try plant(Data("FSC3-payload".utf8), as: .outbox, in: root)
        try plant(Data("FSC".utf8) + Data([0x00]), as: .peerBundles, in: root)
        try plant(Data("FSC".utf8), as: .dedup, in: root)

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.state(of: .outbox) == .unsealedOrUnrecognized)
        #expect(report.state(of: .peerBundles) == .unsealedOrUnrecognized)
        #expect(report.state(of: .dedup) == .unsealedOrUnrecognized)
        #expect(report.v2SealedCount == 0)
        #expect(report.legacySealedCount == 0)
    }

    /// A zero-byte file is its own bucket (an interrupted write, not a migration candidate), and
    /// the quarantine file's ABSENCE is the normal, healthy state — most devices never have one,
    /// so absent has to be a first-class answer rather than a gap.
    @Test func emptyFilesAndTheMissingQuarantineAreTheirOwnStates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try plant(Data(), as: .peerBundles, in: root)

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.state(of: .peerBundles) == .empty)
        #expect(report.state(of: .outboxQuarantine) == .absent)
        #expect(report.emptyCount == 1)
        #expect(report.absentCount == 3)
        #expect(report.isConclusive)
        #expect(report.isClean, "an empty file carries no unconverted blob")
    }

    /// A scope with nothing in it reports four absents, conclusively and cleanly — the answer a
    /// device that has never sent a heart must give.
    @Test func anUntouchedScopeIsFourAbsents() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.absentCount == HeartDropSidecarFormatCensus.Sidecar.allCases.count)
        #expect(report.isConclusive)
        #expect(report.isClean)
    }

    /// The scope overload reads the same corpus as the directory overload — and uses only the
    /// directory half, never the keychain half (the service here holds no key at all).
    @Test func theScopeOverloadSurveysTheScopesDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let blob = try legacyBlob(Data("[]".utf8), key: SymmetricKey(size: .bits256))
        try plant(blob, as: .outbox, in: root)

        let scope = HeartDropStorageScope(
            directory: root,
            keychainService: uniqueHeartDropKeychainService()
        )
        #expect(HeartDropSidecarFormatCensus.survey(in: scope) == HeartDropSidecarFormatCensus.survey(in: root))
        #expect(HeartDropSidecarFormatCensus.survey(in: scope).legacySealedCount == 1)
    }

    // MARK: - Read-only proof

    /// The census writes NOTHING. Every known file is planted, then censused twice, and both the
    /// directory listing and every byte of every file must be identical afterwards — a census that
    /// "helpfully" migrated, truncated, quarantined or even re-touched a file would be doing the
    /// job of a Phase 2 migrator, on a corpus nobody has yet proven convertible.
    @Test func aCensusPassLeavesEveryFileByteIdentical() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = try legacyBlob(Data("[]".utf8), key: SymmetricKey(size: .bits256))
        try plant(legacy, as: .outbox, in: root)
        try plant(Data("FSC2".utf8) + Data([0x01, 0x02, 0x03]), as: .peerBundles, in: root)
        try plant(Data("{}".utf8), as: .dedup, in: root)
        try plant(Data("FSC1".utf8) + Data([0x09]), as: .outboxQuarantine, in: root)

        let before = try snapshot(root)
        #expect(before.count == 4, "the read-only proof must actually have files to protect")

        let first = HeartDropSidecarFormatCensus.survey(in: root)
        let second = HeartDropSidecarFormatCensus.survey(in: root)
        let after = try snapshot(root)

        #expect(after == before, "the census modified the corpus it was only supposed to read")
        #expect(first == second, "two reads of an unchanged corpus disagreed")
        #expect(first.legacySealedCount == 2)
        #expect(first.v2SealedCount == 1)
        #expect(first.unsealedOrUnrecognizedCount == 1)
    }

    /// Censusing an empty directory creates nothing in it, and censusing a directory that does not
    /// exist does not bring one into being. A diagnostic row that materialised heart-drop state
    /// just by being opened would be a privacy surface of its own.
    @Test func aCensusCreatesNothingInAnEmptyOrAbsentDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let absentRoot = uniqueProximityDirectory()
        let report = HeartDropSidecarFormatCensus.survey(in: absentRoot)
        #expect(report.absentCount == HeartDropSidecarFormatCensus.Sidecar.allCases.count)
        #expect(!FileManager.default.fileExists(atPath: absentRoot.path),
                "the census created the directory it was asked to read")
    }
}
