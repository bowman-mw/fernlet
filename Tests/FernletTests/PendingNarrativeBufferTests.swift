// PendingNarrativeBufferTests.swift
// FernletTests
//
// The pending buffer's key custody (period-data design 2026-09-30, §6.5, review R1-F5; invariant
// I21's key half). The buffer seals entries logged while Private is closed under its OWN key, and
// that key used to be read with a collapsing read and minted on any nil. Two ways that lost every
// buffered entry are pinned here: a key minted over buffered entries it cannot open, and the file
// being rewritten under a fresh key. The unreadable-read half lives in `KeyCustodyBoundaryTests`
// (`bufferKeyIsNeverMintedOverAnUnreadableRow`), beside its device-key sibling.
//
// The cap (§6.5, I21's growth half): the buffer holds at most `capacity` entries and REFUSES the
// next one instead of silently evicting the oldest, and a v2 payload (a whole cycle record's JSON)
// round-trips beside v1 narratives, whose files still decode.
//
// Isolation: every test takes its own `uniqueNarrativeBufferScope()` (throwaway directory AND
// throwaway keychain service) and removes both.

import Foundation
import Security
import Testing
import FernletFoundation
import PrivateStoreCore

struct PendingNarrativeBufferTests {

    /// One buffered entry.
    private func payload(_ note: String) -> PendingNarrativePayload {
        PendingNarrativePayload(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-09-30",
            noteBytes: Data(note.utf8),
            symptomFlagsBytes: nil,
            customSymptomScalesBytes: nil
        )
    }

    /// The buffer key's one account, as the buffer files it (a literal on purpose: the account is
    /// part of the at-rest format).
    private static let keyAccount = "com.fernlet.buffer.key.v2"

    /// Removes the scope's directory and key service.
    private func cleanup(_ scope: PendingNarrativeStorageScope) {
        try? FileManager.default.removeItem(at: scope.directory)
        KeychainItem.deleteAll(service: scope.keychainService)
    }

    /// A key that is definitively GONE while the file still holds entries is never re-minted: the
    /// entries were sealed under the lost key, a fresh one cannot open them either, and minting it
    /// would silently turn "unopenable" into "rewritten". Append and drain both refuse by name, the
    /// file is left byte-identical, and no key row appears.
    @Test func aMissingKeyOverBufferedEntriesIsNeverReminted() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanup(scope) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        try buffer.append(payload("held while closed"))
        let fileURL = PendingNarrativeBuffer.fileURL(in: scope.directory)
        let sealedBytes = try Data(contentsOf: fileURL)
        KeychainItem.deleteAll(service: scope.keychainService)

        #expect(throws: PendingNarrativeBufferError.bufferUnopenable) {
            try buffer.append(payload("a second entry"))
        }
        #expect(throws: PendingNarrativeBufferError.bufferUnopenable) {
            _ = try buffer.drainAll()
        }
        #expect(try Data(contentsOf: fileURL) == sealedBytes, "the unopenable file must be left exactly as it was")
        #expect(KeychainItem.load(account: Self.keyAccount, service: scope.keychainService) == nil,
                "a key must never be minted over entries it cannot open")

        // Removing the file is the separate, explicit act; after it a key is minted normally.
        try buffer.purge()
        try buffer.append(payload("after the file was removed"))
        #expect(try buffer.drainAll().count == 1)
    }

    /// The ordinary lifecycle is untouched: the first append mints the key, later appends and
    /// drains reuse it, and a purge followed by an append keeps the SAME key.
    @Test func theFirstAppendMintsTheKeyAndLaterOnesReuseIt() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanup(scope) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        try buffer.append(payload("one"))
        let key = try #require(KeychainItem.load(account: Self.keyAccount, service: scope.keychainService))
        try buffer.append(payload("two"))
        #expect(try buffer.drainAll().map(\.noteBytes) == [Data("one".utf8), Data("two".utf8)])
        try buffer.purge()
        try buffer.append(payload("three"))
        #expect(KeychainItem.load(account: Self.keyAccount, service: scope.keychainService) == key,
                "a purge empties the file; it must not rotate the key")
    }

    /// At the cap the next append THROWS `.full` and changes nothing: every held entry is still
    /// there, oldest first, and the file is byte-identical. (It used to evict the oldest entry with
    /// only an audit line — a note the user saved, gone without a word.)
    @Test func aFullBufferRefusesTheNextEntryAndDropsNothing() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanup(scope) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        for index in 0..<PendingNarrativeBuffer.capacity {
            try buffer.append(payload("entry \(index)"))
        }
        let fileURL = PendingNarrativeBuffer.fileURL(in: scope.directory)
        let before = try Data(contentsOf: fileURL)

        #expect(throws: PendingNarrativeBufferError.full) { try buffer.append(payload("one too many")) }

        #expect(try Data(contentsOf: fileURL) == before, "a refused append must leave the file exactly as it was")
        let held = try buffer.drainAll()
        #expect(held.count == PendingNarrativeBuffer.capacity)
        #expect(held.first?.noteBytes == Data("entry 0".utf8), "the oldest entry must never be evicted")
        #expect(PendingNarrativeBuffer.capacity == 200)
    }

    /// A v2 payload carries a whole cycle record's JSON beside v1 narratives; a v1 payload encodes
    /// exactly as it always did (no new key), so a file written before the field existed decodes.
    @Test func aCycleRecordPayloadRoundTripsBesideVersionOneNarratives() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { cleanup(scope) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        let recordID = UUID()
        let json = Data(#"{"v":2}"#.utf8)
        try buffer.append(payload("a v1 narrative"))
        try buffer.append(PendingNarrativePayload(cycleRecordID: recordID, dayKey: "2026-09-30", cycleRecordJSON: json))

        let drained = try buffer.drainAll()
        #expect(drained.count == 2)
        #expect(drained[0].cycleRecordJSON == nil)
        #expect(drained[1].cycleRecordJSON == json)
        #expect(drained[1].hkExternalUUID == recordID.uuidString && drained[1].dateKey == "2026-09-30")
        #expect(drained[1].noteBytes == nil)

        let v1JSON = try JSONEncoder().encode(payload("old shape"))
        #expect(!(String(data: v1JSON, encoding: .utf8) ?? "").contains("cycleRecordJSON"), "a v1 payload must encode as it always did")
        let legacyFile = #"{"hkExternalUUID":"x","dateKey":"2026-09-01"}"#
        let decoded = try JSONDecoder().decode(PendingNarrativePayload.self, from: Data(legacyFile.utf8))
        #expect(decoded.cycleRecordJSON == nil && decoded.hkExternalUUID == "x")
    }
}
