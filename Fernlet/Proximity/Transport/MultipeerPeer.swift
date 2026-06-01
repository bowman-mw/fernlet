import Foundation
import MultipeerConnectivity

struct MultipeerPeer: Hashable, Identifiable {
    let id: UUID
    let displayName: String
    let discoveryInfo: [String: String]?
    let advertisedFingerprint: String?
    let underlying: MCPeerID  // internal for @testable access

    static func == (lhs: MultipeerPeer, rhs: MultipeerPeer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

protocol MCPeerIDStoring {
    func load() -> MCPeerID?
    func save(_ peerID: MCPeerID)
}

struct FileMCPeerIDStore: MCPeerIDStoring {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return support.appendingPathComponent("FernletPeerID.archive")
        }()
    }

    func load() -> MCPeerID? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data)
    }

    func save(_ peerID: MCPeerID) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
