import Testing
import Foundation
@testable import Fernlet

@Suite(.serialized) @MainActor
struct FriendPhotoSharingServiceTests {
    @Test func cacheSyncMarkerSurvivesTransferState() throws {
        let service = FriendPhotoSharingService(store: makeTestStore())
        let peer = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Friend",
            signingPublicKey: Data([1, 2, 3]),
            keyAgreementPublicKey: Data([4, 5, 6]),
            fingerprint: "friend-fingerprint",
            rangingMode: .uwb,
            firstSeenAt: Date()
        )

        #expect(service.markCacheSyncNeeded(for: .connected(peer: peer)) == true)
        #expect(service.markCacheSyncNeeded(for: .transferring(peer: peer, progress: 0.5)) == false)
        #expect(service.markCacheSyncNeeded(for: .connected(peer: peer)) == false)
        #expect(service.markCacheSyncNeeded(for: .ended(reason: .userCancelled)) == false)
        #expect(service.markCacheSyncNeeded(for: .connected(peer: peer)) == true)
    }
}
