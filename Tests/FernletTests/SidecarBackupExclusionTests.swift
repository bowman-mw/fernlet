// SidecarBackupExclusionTests.swift
// FernletTests
//
// Bug confirmation 2026-10-15 §5: the four device-local social ledgers — `ClosenessLedger.json`,
// `FriendStateCache.json`, `ModerationLedger.json` and `ActivityLedger.json` — were written with
// `.completeFileProtection` but never excluded from iCloud device backups, so a dated co-presence log
// (friend fingerprints × days × counts), friends' shared wellbeing states, who reported whom and the
// activities joined rode every iCloud Backup, where Apple holds the keys without Advanced Data
// Protection. Every store's doc said its file "never leaves the device".
//
// One cell per file, each through the store's own write, plus the heal: a file an earlier build wrote
// without the flag is re-marked when its store opens it. The photo wall's preferences are deliberately
// not here — whether they ride a backup is the owner's call.

import Foundation
import Testing
import FernletConnections
import FernletDomainModel
@testable import FernletSocial
import ProximityKit

@MainActor
@Suite(.serialized)
struct SidecarBackupExclusionTests {

    /// A fresh scratch file under its own directory.
    private func scratchFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarBackupExclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// Whether `url` carries `isExcludedFromBackup` (nil when the file is not there to ask).
    private func isExcluded(_ url: URL) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    @Test func theClosenessLedgerIsExcludedFromDeviceBackups() throws {
        let url = try scratchFile("ClosenessLedger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = ClosenessLedger(fileURL: url)
        ledger.recordSession(fingerprint: "abcd1234")
        #expect(try isExcluded(url) == true, "the dated co-presence log rides iCloud device backups")
    }

    @Test func theFriendStateCacheIsExcludedFromDeviceBackups() throws {
        let url = try scratchFile("FriendStateCache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = FriendStateCache(fileURL: url)
        cache.record(fingerprint: "abcd1234", fuzzyState: .struggling, appearance: .standard)
        #expect(try isExcluded(url) == true, "a friend's shared state rides iCloud device backups")
    }

    @Test func theModerationLedgerIsExcludedFromDeviceBackups() throws {
        let url = try scratchFile("ModerationLedger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = ModerationLedger(fileURL: url)
        ledger.recordLocalReport(reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                                 subjectSigningPublicKey: Data([2]), itemID: UUID(),
                                 contentHash: Data([0xAB]), reason: "offensive")
        #expect(try isExcluded(url) == true, "who reported whom rides iCloud device backups")
    }

    @Test func theActivityLedgerIsExcludedFromDeviceBackups() throws {
        let url = try scratchFile("ActivityLedger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Held in a `let`: the manager holds its host unowned.
        let host = RecipeTransferTestHost()
        let manager = ProximityActivityManager(store: host, fileURL: url)
        manager.leaveJoined(activityID: UUID())
        #expect(try isExcluded(url) == true, "the activities joined ride iCloud device backups")
    }

    /// A file an earlier build wrote — included in backups, as every one of them was — is re-marked the
    /// moment its store opens it, before any new write: the backup a user's phone takes tonight must not
    /// carry yesterday's ledger because nothing changed today.
    @Test func aFileAnEarlierBuildWroteIsHealedWhenItsStoreOpens() throws {
        let url = try scratchFile("FriendStateCache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(#"{"version":1,"states":[]}"#.utf8).write(to: url)
        #expect(try isExcluded(url) == false)
        _ = FriendStateCache(fileURL: url)
        #expect(try isExcluded(url) == true, "opening the store left an earlier build's file in backups")
    }
}
