import XCTest
import CryptoKit
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit

@MainActor
final class ModerationTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Content hash

    func testContentHashStableByArtworkAndDistinctBySlotAndPixels() {
        let texA = ItemGridTexture(cols: 8, rows: 8, palette: ["#000000"], pixels: Array(repeating: 0, count: 64))
        var altPixels = Array(repeating: 0, count: 64); altPixels[0] = -1
        let texB = ItemGridTexture(cols: 8, rows: 8, palette: ["#000000"], pixels: altPixels)

        XCTAssertEqual(ModerationContentHash.of(texture: texA, slot: .hat),
                       ModerationContentHash.of(texture: texA, slot: .hat), "same artwork+slot → same hash")
        XCTAssertNotEqual(ModerationContentHash.of(texture: texA, slot: .hat),
                          ModerationContentHash.of(texture: texA, slot: .body), "slot participates in the hash")
        XCTAssertNotEqual(ModerationContentHash.of(texture: texA, slot: .hat),
                          ModerationContentHash.of(texture: texB, slot: .hat), "changed pixels → different hash")
    }

    // MARK: - Local ledger

    func testLedgerReportHidesRetractRestoresAndReportIsIdempotent() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let ledger = ModerationLedger(fileURL: url, now: { self.fixedNow })
        let hash = Data([0xAB, 0xCD])

        ledger.recordLocalReport(reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                                 subjectSigningPublicKey: Data([2]), itemID: UUID(), contentHash: hash, reason: "offensive")
        XCTAssertTrue(ledger.isLocallyReported(contentHash: hash, reporterFingerprint: "me"))

        // Re-reporting the same artwork de-dupes (deterministic id).
        ledger.recordLocalReport(reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                                 subjectSigningPublicKey: Data([2]), itemID: UUID(), contentHash: hash, reason: "sexual")
        XCTAssertEqual(ledger.rows.filter { $0.kind == .report }.count, 1)

        // Retract supersedes the report.
        ledger.recordLocalRetract(reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                                  subjectSigningPublicKey: Data([2]), itemID: UUID(), contentHash: hash)
        XCTAssertFalse(ledger.isLocallyReported(contentHash: hash, reporterFingerprint: "me"))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Verdict math

    private func report(reporter: UInt8, subject: UInt8, hash: UInt8, seq: UInt64 = 1, ageDays: Double = 0) -> ModerationLedgerEntry {
        ModerationLedgerEntry(
            id: "report:\(reporter):\(hash)", kind: .report,
            reporterSigningPublicKey: Data([reporter]), subjectSigningPublicKey: Data([subject]),
            itemID: UUID(), contentHash: Data([hash]), reasonToken: "offensive", reporterSeq: seq,
            createdAt: fixedNow.addingTimeInterval(-ageDays * 86_400))
    }

    func testDistinctReportersRetractAndDecay() {
        let h: UInt8 = 9
        var rows = [report(reporter: 1, subject: 5, hash: h), report(reporter: 2, subject: 5, hash: h)]
        XCTAssertEqual(ModerationEconomy.distinctReporters(ofContentHash: Data([h]), in: rows, now: fixedNow), 2)

        // Reporter 1 retracts (higher seq) → 1 live reporter.
        rows.append(ModerationLedgerEntry(
            id: "retract:1:\(h)", kind: .retract, reporterSigningPublicKey: Data([1]),
            subjectSigningPublicKey: Data([5]), itemID: UUID(), contentHash: Data([h]),
            reasonToken: "other", reporterSeq: 2, createdAt: fixedNow))
        XCTAssertEqual(ModerationEconomy.distinctReporters(ofContentHash: Data([h]), in: rows, now: fixedNow), 1)

        // A 200-day-old report does not count.
        let stale = [report(reporter: 3, subject: 5, hash: h, ageDays: 200)]
        XCTAssertEqual(ModerationEconomy.distinctReporters(ofContentHash: Data([h]), in: stale, now: fixedNow), 0)
    }

    func testItemUnlistableThreshold() {
        let rows = [report(reporter: 1, subject: 5, hash: 9), report(reporter: 2, subject: 5, hash: 9)]
        XCTAssertTrue(ModerationEconomy.unlistableContentHashes(ofDesigner: Data([5]), in: rows, now: fixedNow).contains(Data([9])))
        let single = [report(reporter: 1, subject: 5, hash: 9)]
        XCTAssertFalse(ModerationEconomy.unlistableContentHashes(ofDesigner: Data([5]), in: single, now: fixedNow).contains(Data([9])))
    }

    func testDesignerBanNeedsBroadParticipationNotAFewReporters() {
        // Two reporters spamming three of a designer's items: per-reporter cap starves the 3rd item → no ban.
        let twoReporters = [
            report(reporter: 1, subject: 5, hash: 1), report(reporter: 2, subject: 5, hash: 1),
            report(reporter: 1, subject: 5, hash: 2), report(reporter: 2, subject: 5, hash: 2),
            report(reporter: 1, subject: 5, hash: 3), report(reporter: 2, subject: 5, hash: 3),
        ]
        XCTAssertFalse(ModerationEconomy.shouldBanDesigner(subjectKey: Data([5]), in: twoReporters, now: fixedNow))

        // Three reporters spread two-per across three items (each within the per-reporter cap) → ban.
        let threeReporters = [
            report(reporter: 1, subject: 5, hash: 1), report(reporter: 2, subject: 5, hash: 1),
            report(reporter: 1, subject: 5, hash: 2), report(reporter: 3, subject: 5, hash: 2),
            report(reporter: 2, subject: 5, hash: 3), report(reporter: 3, subject: 5, hash: 3),
        ]
        XCTAssertTrue(ModerationEconomy.shouldBanDesigner(subjectKey: Data([5]), in: threeReporters, now: fixedNow))
    }

    // MARK: - One-hop report relay (Phase 3b)

    func testRelayAcceptsSenderSignedRejectsSpoofedReporterAndForgedSignature() {
        let priv = Curve25519.Signing.PrivateKey()
        let senderKey = priv.publicKey.rawRepresentation
        let hash = Data([0xAB, 0xCD])
        let row = ModerationLedgerEntry(
            id: "report:x:abcd", kind: .report,
            reporterSigningPublicKey: senderKey, subjectSigningPublicKey: Data([5]),
            itemID: UUID(), contentHash: hash, reasonToken: "offensive", reporterSeq: 1,
            createdAt: fixedNow)
        let sig = try! priv.signature(for: canonicalBytes(for: row))
        let payload = ModerationReportPayload(reports: [SignedModerationReport(entry: row, signature: sig)])
        let later = fixedNow.addingTimeInterval(3600)

        // Valid: signed by the sender, reporter == sender.
        XCTAssertEqual(ModerationReportRelay.verifiedRows(from: payload, senderSigningKey: senderKey, now: later).count, 1)
        // One-hop: the same bundle delivered by a DIFFERENT sender is rejected (you may only relay your own).
        XCTAssertTrue(ModerationReportRelay.verifiedRows(from: payload, senderSigningKey: Data([9, 9, 9]), now: later).isEmpty)
        // Forged signature is rejected.
        let forged = ModerationReportPayload(reports: [SignedModerationReport(entry: row, signature: Data(repeating: 0, count: 64))])
        XCTAssertTrue(ModerationReportRelay.verifiedRows(from: forged, senderSigningKey: senderKey, now: later).isEmpty)
    }

    func testLedgerIngestForeignStoresPeerRows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let ledger = ModerationLedger(fileURL: url, now: { self.fixedNow })
        let foreign = ModerationLedgerEntry(
            id: "report:peer:99", kind: .report, reporterSigningPublicKey: Data([2]),
            subjectSigningPublicKey: Data([5]), itemID: UUID(), contentHash: Data([0x99]),
            reasonToken: "offensive", reporterSeq: 1, createdAt: fixedNow)
        ledger.ingestForeign([foreign])
        XCTAssertEqual(ledger.rows.count, 1)
        XCTAssertEqual(ModerationEconomy.distinctReporters(ofContentHash: Data([0x99]), in: ledger.rows, now: fixedNow), 1)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Ledger bounds (M13): a hostile reporter must not be able to evict anyone else's rows

    /// One foreign row from `reporter`, with a per-row-unique content hash so nothing de-dupes.
    private func floodRow(reporter: Data, index: Int, at date: Date) -> ModerationLedgerEntry {
        let hash = Data(withUnsafeBytes(of: UInt64(index).bigEndian) { Array($0) })
        return ModerationLedgerEntry(
            id: "report:\(ModerationLedgerEntry.hex(reporter)):\(ModerationLedgerEntry.hex(hash))",
            kind: .report, reporterSigningPublicKey: reporter, subjectSigningPublicKey: Data([5]),
            itemID: UUID(), contentHash: hash, reasonToken: "offensive", reporterSeq: 1, createdAt: date)
    }

    /// Delivers `rows` the way the relay does — one wire payload's worth per call.
    private func ingestInWirePayloads(_ rows: [ModerationLedgerEntry], into ledger: ModerationLedger) {
        var offset = 0
        while offset < rows.count {                                   // bounded by rows.count
            let end = min(offset + ModerationReportPayload.maxReports, rows.count)
            ledger.ingestForeign(Array(rows[offset..<end]))
            offset = end
        }
    }

    /// A peer flooding the relay must never evict this device's OWN reports — the attack that turns a
    /// flat oldest-first eviction into a way to un-hide artwork the user reported.
    func testForeignFloodCannotEvictLocalReports() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let ledger = ModerationLedger(fileURL: url, now: { self.fixedNow })
        let localHashes = (0..<5).map { Data([0xA0, UInt8($0)]) }
        for hash in localHashes {
            ledger.recordLocalReport(reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                                     subjectSigningPublicKey: Data([2]), itemID: UUID(),
                                     contentHash: hash, reason: "offensive")
        }

        // 40 wire payloads (1280 rows) from ONE reporter, all dated in the future so a naive
        // newest-wins trim would keep every one of them and drop all five local rows.
        let flooder = Data([0xFF, 0xFE])
        let future = fixedNow.addingTimeInterval(86_400)
        ingestInWirePayloads((0..<1280).map { floodRow(reporter: flooder, index: $0, at: future) }, into: ledger)

        for hash in localHashes {
            XCTAssertTrue(ledger.isLocallyReported(contentHash: hash, reporterFingerprint: "me"),
                          "a foreign flood must not evict this device's own report")
        }
        let flooderFingerprint = IdentityService.fingerprint(of: flooder)
        let flooderRows = ledger.rows.filter { IdentityService.fingerprint(of: $0.reporterSigningPublicKey) == flooderFingerprint }
        XCTAssertLessThanOrEqual(flooderRows.count, ModerationLedger.maxRowsPerReporter)
        XCTAssertLessThanOrEqual(ledger.rows.count, ModerationLedger.maxRows)
        try? FileManager.default.removeItem(at: url)
    }

    /// Max-min fairness, the general case: many colluding flooders are drained down to a shared
    /// allowance before the one reporter holding a single row loses it.
    func testQuietReporterSurvivesManyFlooders() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let ledger = ModerationLedger(fileURL: url, now: { self.fixedNow })
        let quiet = Data([0x01, 0x02, 0x03])
        ingestInWirePayloads([floodRow(reporter: quiet, index: 7, at: fixedNow)], into: ledger)

        for reporter in 0..<20 {
            let key = Data([0xB0, UInt8(reporter)])
            ingestInWirePayloads((0..<200).map { floodRow(reporter: key, index: $0, at: fixedNow) }, into: ledger)
        }

        let quietFingerprint = IdentityService.fingerprint(of: quiet)
        XCTAssertTrue(ledger.rows.contains { IdentityService.fingerprint(of: $0.reporterSigningPublicKey) == quietFingerprint },
                      "20 flooders must not cost the single-row reporter its only row")
        XCTAssertLessThanOrEqual(ledger.rows.count, ModerationLedger.maxRows)
        try? FileManager.default.removeItem(at: url)
    }

    /// The sidecar is external input: a tampered or older-build file stuffed with one reporter's rows
    /// must be bounded by the SAME fair rule on the way in, not by a flat oldest-first trim (which
    /// would let the file itself evict every other reporter at launch).
    func testLoadAppliesTheSameFairBound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let flooder = Data([0xEE])
        let quiet = Data([0x11])
        let rows = (0..<5_000).map { floodRow(reporter: flooder, index: $0, at: fixedNow) }
            + (0..<3).map { floodRow(reporter: quiet, index: 100_000 + $0, at: fixedNow) }
        // Written as the sidecar's own shape (`{"version":…,"rows":[…]}`) rather than through the
        // ledger, so the bound under test is `load()`'s and not `ingestForeign`'s.
        let encoded = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        try Data("{\"version\":1,\"rows\":\(encoded)}".utf8).write(to: url)

        let ledger = ModerationLedger(fileURL: url, now: { self.fixedNow })
        let flooderFingerprint = IdentityService.fingerprint(of: flooder)
        let quietFingerprint = IdentityService.fingerprint(of: quiet)
        XCTAssertLessThanOrEqual(ledger.rows.count, ModerationLedger.maxRows)
        XCTAssertLessThanOrEqual(
            ledger.rows.filter { IdentityService.fingerprint(of: $0.reporterSigningPublicKey) == flooderFingerprint }.count,
            ModerationLedger.maxRowsPerReporter)
        XCTAssertEqual(
            ledger.rows.filter { IdentityService.fingerprint(of: $0.reporterSigningPublicKey) == quietFingerprint }.count, 3,
            "the quiet reporter's rows survive a 5,000-row file from someone else")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Relay size bounds (M13)

    /// A signature the sender computes itself does not bound the row's SIZE: a well-signed multi-MB
    /// row would otherwise be verified (expensive) and then persisted verbatim forever. Oversized
    /// fields are REJECTED, never clamped — clamping would mutate the signed bytes.
    func testRelayRejectsOversizedFields() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let senderKey = priv.publicKey.rawRepresentation
        let later = fixedNow.addingTimeInterval(3600)

        func signedPayload(contentHash: Data, subject: Data, reason: String) throws -> ModerationReportPayload {
            let row = ModerationLedgerEntry(
                id: "report:x:1", kind: .report, reporterSigningPublicKey: senderKey,
                subjectSigningPublicKey: subject, itemID: UUID(), contentHash: contentHash,
                reasonToken: reason, reporterSeq: 1, createdAt: fixedNow)
            let sig = try priv.signature(for: canonicalBytes(for: row))
            return ModerationReportPayload(reports: [SignedModerationReport(entry: row, signature: sig)])
        }
        let normalHash = Data(repeating: 0xAB, count: 32)

        let hugeHash = try signedPayload(contentHash: Data(repeating: 7, count: 500_000),
                                         subject: Data([5]), reason: "offensive")
        XCTAssertTrue(ModerationReportRelay.verifiedRows(from: hugeHash, senderSigningKey: senderKey, now: later).isEmpty,
                      "a 500 KB contentHash is rejected")
        let hugeReason = try signedPayload(contentHash: normalHash, subject: Data([5]),
                                           reason: String(repeating: "z", count: 1_024))
        XCTAssertTrue(ModerationReportRelay.verifiedRows(from: hugeReason, senderSigningKey: senderKey, now: later).isEmpty,
                      "a 1 KB reasonToken is rejected")
        let hugeSubject = try signedPayload(contentHash: normalHash, subject: Data(repeating: 3, count: 4_096),
                                            reason: "offensive")
        XCTAssertTrue(ModerationReportRelay.verifiedRows(from: hugeSubject, senderSigningKey: senderKey, now: later).isEmpty,
                      "a 4 KB subject key is rejected")

        // No wire break: an ordinary 32-byte-hash row from the same signer still verifies.
        let ordinary = try signedPayload(contentHash: normalHash, subject: Data([5]), reason: "offensive")
        XCTAssertEqual(ModerationReportRelay.verifiedRows(from: ordinary, senderSigningKey: senderKey, now: later).count, 1)
    }

    /// L21 anti-regression at the wire layer: `buildPayload` deliberately does NOT drop rows whose
    /// subject is the recipient. Those rows are the ONLY evidence a device ever gets that it is the
    /// one being reported (the relay is one-hop, so nobody else can forward them), so filtering them
    /// silently deletes the self-ban. Paired with
    /// `ModerationBanTests.testForeignRowsNamingLocalKeySelfBanTheShop`.
    func testRelayCarriesRowsNamingTheReportedMakerAsSubject() throws {
        let service = "com.fernlet.identity.test.\(UUID().uuidString)"
        let identity = IdentityService(keychainService: service)
        // `init` does not provision: without this the signing key is nil, `sign` throws
        // `notProvisioned`, and `buildPayload` would return zero rows for the wrong reason.
        try identity.ensureProvisioned()
        defer { KeychainItem.deleteAll(service: service) }
        let makerKey = Data(repeating: 0x5A, count: 32)   // stands in for the recipient we are reporting
        let row = ModerationLedgerEntry(
            id: "report:me:1", kind: .report,
            reporterSigningPublicKey: identity.localSigningPublicKey, subjectSigningPublicKey: makerKey,
            itemID: UUID(), contentHash: Data([0xAB, 0xCD]), reasonToken: "offensive",
            reporterSeq: 1, createdAt: fixedNow)

        let payload = ModerationReportRelay.buildPayload(ownReports: [row], identity: identity)
        XCTAssertEqual(payload.reports.count, 1)
        XCTAssertEqual(payload.reports.first?.entry.subjectSigningPublicKey, makerKey,
                       "the row naming the maker as subject must still be sent — it is the self-ban's only evidence")
    }

    // MARK: - Trust vault

    func testVaultReportStampsReasonAndBlocks() {
        let peer = ProximityTrustedPeerRecord(
            displayName: "Sam", fingerprint: "abcdef01",
            signingPublicKey: Data([7, 7, 7]), keyAgreementPublicKey: Data([8]), mode: .friend)
        let vault = ProximityTrustVault(initialPeers: [peer])

        vault.report(signingPublicKey: Data([7, 7, 7]), reason: ReportReason.hateful.rawValue, blockAlso: true)
        let updated = vault.peer(signingPublicKey: Data([7, 7, 7]))
        XCTAssertNotNil(updated?.reportedAt)
        XCTAssertEqual(updated?.reportReason, ReportReason.hateful.rawValue)
        XCTAssertNotNil(updated?.blockedAt, "reporting blocks by default")
        XCTAssertTrue(vault.isBlockedProximitySigningKey(Data([7, 7, 7])))
    }
}
