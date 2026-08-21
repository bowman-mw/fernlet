@testable import ProximityKit
import Foundation
import MultipeerConnectivity
import UIKit
import Testing

/// `FernletPeerID.archive` is part of the identity the delete-all funnel rotates.
///
/// The archive holds `UIDevice.current.name` — in practice the user's own first name — plus the
/// stable `MCPeerID` every stable radio (mesh, recipe share) re-advertises. It used to survive
/// "Delete everything", so the promised "brand-new Fernlet identity" kept broadcasting the old name
/// and the old on-air identifier even after the Ed25519/X25519 keypairs were wiped.
/// `MeshNetworkManager.wipeIdentityForDeleteAll` now clears it through
/// ``FileMCPeerIDStore/clearForDeleteAll()``; these tests pin that seam and the two properties the
/// wiring depends on — a fresh peer id is minted lazily afterwards, and clearing mid-session cannot
/// disturb an `MCSession` already running on the old one.
///
/// Every case injects its own archive URL: the production default is a process-global path in
/// Application Support, and parallel suites share it.
@MainActor
struct PeerIDArchiveWipeTests {

    private func archiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerIDArchiveWipeTests-\(UUID().uuidString).archive")
    }

    /// The clear removes the archive file, and the store then reports no peer identity at all.
    @Test func clearRemovesTheArchive() throws {
        let fileURL = archiveURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = FileMCPeerIDStore(fileURL: fileURL)
        store.save(MCPeerID(displayName: "Wiped Phone"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.load() != nil)

        try store.clearForDeleteAll()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path),
                "the peer-identity archive survived the wipe")
        #expect(store.load() == nil, "a wiped archive must not still vend the pre-wipe peer id")
    }

    /// Clearing an archive that was never written is success, not an error — the wipe runs on a
    /// device that may never have started a radio.
    @Test func clearingAnAbsentArchiveIsNotAFailure() {
        let store = FileMCPeerIDStore(fileURL: archiveURL())

        #expect(throws: Never.self) {
            try store.clearForDeleteAll()
        }
    }

    /// After the clear, the next radio to start mints a FRESH peer id and archives it — the mint is
    /// lazy (`MeshMultipeerSession.init`), so nothing has to re-seed the file during the wipe.
    @Test func aFreshPeerIDIsMintedAfterTheClear() throws {
        let fileURL = archiveURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = FileMCPeerIDStore(fileURL: fileURL)
        let original = MCPeerID(displayName: "Wiped Phone")
        store.save(original)

        try store.clearForDeleteAll()
        let session = MeshMultipeerSession(peerIDStore: store)

        #expect(session.localPeerID != original, "the wiped peer id was re-advertised after the wipe")
        #expect(session.localPeerID.displayName == UIDevice.current.name)
        let reloaded = try #require(store.load())
        #expect(reloaded != original, "the minted peer id must replace the wiped one in the archive")
    }

    /// Clearing mid-session cannot disturb a live `MCSession`: `localPeerID` is resolved once at
    /// init from the already-read archive, so the file removal has nothing to reach into.
    @Test func clearingDoesNotDisturbALiveSessionPeerID() throws {
        let fileURL = archiveURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = FileMCPeerIDStore(fileURL: fileURL)
        let session = MeshMultipeerSession(peerIDStore: store)
        let live = session.localPeerID

        try store.clearForDeleteAll()

        #expect(session.localPeerID == live)
        #expect(store.load() == nil)
    }
}
