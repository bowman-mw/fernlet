import ProximityKit
import Foundation
import MultipeerConnectivity
import Testing
import FernletDomainModel
@testable import Fernlet

struct MultipeerPeerTests {
    @Test func filePeerIDStorePersistsPeerID() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FernletPeerIDTests-\(UUID().uuidString).archive")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = FileMCPeerIDStore(fileURL: fileURL)
        let peerID = MCPeerID(displayName: "Test Peer")

        store.save(peerID)
        let loaded = try #require(store.load())

        #expect(loaded.displayName == peerID.displayName)
    }
}
