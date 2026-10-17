// ModerationLedgerQuarantineTests.swift
// FernletTests
//
// Bug confirmation 2026-10-15 §4: `ModerationLedger` loaded its file through the naive sidecar read,
// which answers nil for an absent, an unreadable AND an undecodable file alike, and treated nil as "no
// reports" — so the next report wrote that near-empty ledger over the real one. Every report this
// device had filed was forgotten: `isLocallyReported` stopped hiding the reported items, the ban
// reconciliation lost its evidence, and this device stopped relaying its reports.
//
// The ledger now reads through the classified `JSONSidecarFile.read()`: an undecodable file is
// quarantined to `ModerationLedger.json.corrupt` before anything is written, an unreadable one blocks
// every save until a read succeeds (and the reports recorded meanwhile are merged into the file's), and
// one row that will not decode costs only itself.

import Foundation
import Testing
import FernletDomainModel
@testable import FernletSocial

@MainActor
@Suite(.serialized)
struct ModerationLedgerQuarantineTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A fresh scratch ledger file under its own directory.
    private func scratchFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModerationLedgerQuarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ModerationLedger.fileURL(in: directory)
    }

    /// Files one local report for the artwork hashed `hash`.
    private func report(_ hash: UInt8, on ledger: ModerationLedger) {
        ledger.recordLocalReport(reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                                 subjectSigningPublicKey: Data([2]), itemID: UUID(),
                                 contentHash: Data([hash]), reason: "offensive")
    }

    private func isReported(_ hash: UInt8, on ledger: ModerationLedger) -> Bool {
        ledger.isLocallyReported(contentHash: Data([hash]), reporterFingerprint: "me")
    }

    @Test func anUndecodableLedgerIsQuarantinedBeforeTheNextReportIsWritten() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let damaged = Data("{\"version\":1,\"rows\":[{\"truncated".utf8)
        try damaged.write(to: url)

        let ledger = ModerationLedger(fileURL: url, now: { now })
        #expect(ledger.rows.isEmpty)
        let quarantine = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.contents(atPath: quarantine.path) == damaged,
                "the undecodable ledger was not moved aside")

        report(0x01, on: ledger)
        #expect(FileManager.default.contents(atPath: quarantine.path) == damaged,
                "the next report overwrote the only copy of the damaged ledger")
        #expect(isReported(0x01, on: ModerationLedger(fileURL: url, now: { now })))
    }

    @Test func anUnreadableLedgerIsNeverOverwrittenAndMergesOnceItReads() throws {
        let url = try scratchFile()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        report(0x01, on: ModerationLedger(fileURL: url, now: { now }))
        let original = try Data(contentsOf: url)

        // No read permission: the closest a test gets to a `.completeFileProtection` file read while the
        // device is locked. The atomic write would still replace it (a rename needs only the folder).
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let ledger = ModerationLedger(fileURL: url, now: { now })
        report(0x02, on: ledger)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original, "a report filed over an unread ledger overwrote it")

        // Readable again: the next save reads the file first and keeps both sides' reports.
        report(0x03, on: ledger)
        let reread = ModerationLedger(fileURL: url, now: { now })
        #expect(isReported(0x01, on: reread), "the file's own report was lost")
        #expect(isReported(0x02, on: reread), "the report filed while the file was unread was lost")
        #expect(isReported(0x03, on: reread))
    }

    @Test func oneRowThatWillNotDecodeCostsOnlyItself() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = ModerationLedger(fileURL: url, now: { now })
        report(0x01, on: writer)
        report(0x02, on: writer)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        #expect(rows.count == 2)
        rows[1]["reporterSeq"] = "not a number"
        object["rows"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let ledger = ModerationLedger(fileURL: url, now: { now })
        #expect(ledger.rows.count == 1, "one undecodable row took every report in the file with it")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    @Test func clearAllRemovesTheQuarantineWithTheLedger() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: url)
        let ledger = ModerationLedger(fileURL: url, now: { now })
        report(0x01, on: ledger)
        let quarantine = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: quarantine.path))

        ledger.clearAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: quarantine.path),
                "the damaged ledger — who reported whom — outlived Delete Everything")
    }
}
