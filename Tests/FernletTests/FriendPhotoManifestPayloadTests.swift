import ProximityKit
import Testing
import Foundation
import FernletDomainModel
@testable import Fernlet

// MARK: - FriendPhotoManifestPayload

@Suite @MainActor struct FriendPhotoManifestPayloadTests {

    // Each entry in the manifest carries a non-optional sender fingerprint,
    // so block-filtering can happen before any bytes are requested over the wire.
    @Test func entriesCarrySenderFingerprint() {
        let id = UUID()
        let entry = FriendPhotoManifestEntry(id: id, senderFingerprint: "alice-fp")
        let payload = FriendPhotoManifestPayload(entries: [entry])
        #expect(payload.entries.count == 1)
        #expect(payload.entries[0].id == id)
        #expect(payload.entries[0].senderFingerprint == "alice-fp")
    }

    @Test func payloadRoundTripsThroughJSON() throws {
        let entries = [
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "alice-fp"),
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "bob-fp"),
        ]
        let original = FriendPhotoManifestPayload(entries: entries)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FriendPhotoManifestPayload.self, from: data)
        #expect(decoded == original)
    }

    // Pre-filtering: blocked-sender photos are excluded from the request list
    // before any network traffic is initiated.
    @Test func blockedSenderPhotosAreNotRequested() {
        let store = makeTestStore()
        let blockedKey = Data([1, 2, 3])
        let blockedFingerprint = IdentityService.fingerprint(of: blockedKey)
        store.blockProximityPeer(signingPublicKey: blockedKey)

        let blockedID = UUID()
        let allowedID = UUID()
        let manifest = FriendPhotoManifestPayload(entries: [
            FriendPhotoManifestEntry(id: blockedID, senderFingerprint: blockedFingerprint),
            FriendPhotoManifestEntry(id: allowedID, senderFingerprint: "allowed-fp"),
        ])

        let haveIDs: Set<UUID> = []
        let toRequest = manifest.entries
            .filter { !haveIDs.contains($0.id) }
            .filter { !store.isBlockedFingerprint($0.senderFingerprint) }
            .map(\.id)

        #expect(toRequest == [allowedID])
        #expect(!toRequest.contains(blockedID))
    }

    // Photos already in the local cache are excluded from the request list
    // regardless of sender.
    @Test func alreadyCachedPhotosAreNotRequested() {
        let cachedID = UUID()
        let newID = UUID()
        let manifest = FriendPhotoManifestPayload(entries: [
            FriendPhotoManifestEntry(id: cachedID, senderFingerprint: "alice-fp"),
            FriendPhotoManifestEntry(id: newID, senderFingerprint: "alice-fp"),
        ])

        let haveIDs: Set<UUID> = [cachedID]
        let toRequest = manifest.entries
            .filter { !haveIDs.contains($0.id) }
            .map(\.id)

        #expect(toRequest == [newID])
        #expect(!toRequest.contains(cachedID))
    }

    // When every entry is from a blocked sender, nothing is requested.
    @Test func allBlockedSendersProducesEmptyRequest() {
        let store = makeTestStore()
        let blockedKey = Data([1, 2, 3])
        let blockedFingerprint = IdentityService.fingerprint(of: blockedKey)
        store.blockProximityPeer(signingPublicKey: blockedKey)

        let manifest = FriendPhotoManifestPayload(entries: [
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: blockedFingerprint),
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: blockedFingerprint),
        ])

        let haveIDs: Set<UUID> = []
        let toRequest = manifest.entries
            .filter { !haveIDs.contains($0.id) }
            .filter { !store.isBlockedFingerprint($0.senderFingerprint) }
            .map(\.id)

        #expect(toRequest.isEmpty)
    }
}
