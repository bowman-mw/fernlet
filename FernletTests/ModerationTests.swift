import XCTest
import CryptoKit
import FernletDomainModel
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
        let sig = try! priv.signature(for: ModerationLedgerEntry.canonicalSignedBytes(row))
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
