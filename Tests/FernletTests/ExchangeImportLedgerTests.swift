import Foundation
import Testing
@testable import Fernlet

/// Replays can arrive after the canonical write succeeds but before Shortcuts receives its result.
/// These tests pin the metadata-only ledger that makes that retry return the original import.
@MainActor
struct ExchangeImportLedgerTests {
    @Test func replayUsesTheOriginalResultAndResetErasesIt() throws {
        let ledger = ExchangeImportLedger(fileURL: temporaryLedgerURL())
        let packetID = UUID()
        let hash = String(repeating: "a", count: 64)

        try ledger.record(packetID: packetID, hash: hash, resultID: "recipe-result", kind: .recipe)
        #expect(try ledger.result(for: packetID, hash: hash)?.resultID == "recipe-result")
        try ledger.record(packetID: packetID, hash: hash, resultID: "replacement-result", kind: .recipe)
        #expect(try ledger.result(for: packetID, hash: hash)?.resultID == "replacement-result")
        try ledger.reset()
        #expect(try ledger.result(for: packetID, hash: hash) == nil)
    }

    @Test func ledgerCapsPersistentReplayRecords() throws {
        let fileURL = temporaryLedgerURL()
        let ledger = ExchangeImportLedger(fileURL: fileURL)
        let hash = String(repeating: "b", count: 64)

        for index in 0..<(ExchangeImportLedger.maxEntries + 10) {
            try ledger.record(packetID: UUID(), hash: hash, resultID: "result-\(index)", kind: .workoutPlan)
        }
        let data = try Data(contentsOf: fileURL)
        let entries = try JSONDecoder().decode([ExchangeImportLedgerEntry].self, from: data)

        #expect(entries.count == ExchangeImportLedger.maxEntries)
        #expect(entries.first?.resultID == "result-\(ExchangeImportLedger.maxEntries + 9)")
        try ledger.reset()
    }

    private func temporaryLedgerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ExchangeImportLedger.json", isDirectory: false)
    }
}
