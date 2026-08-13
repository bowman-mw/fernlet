@testable import ProximityKit
import Testing
import Foundation
import Observation
import FernletDomainModel
@testable import Fernlet

// MARK: - MeshFavoriteObservationTests

// Feedback 10 ("photo heart does nothing"): the heart is a per-session favorite toggle. It never
// re-rendered because `photoWallPreferences` is `@ObservationIgnored` (its `photoWallPosts` getter
// mutates it during body evaluation, so it cannot be plainly observed). `toggleFavorite` now bumps
// an observed `favoritesRevision` counter that `favoritePhotoID(for:)` and `photoWallPosts`
// touch-read, so both the viewer heart and the wall cover update live.
//
// The suite holds a strong `store` reference so the manager's `unowned let store` never dangles
// mid-test (mirrors MeshNetworkManagerTests).
@Suite(.serialized) @MainActor
struct MeshFavoriteObservationTests {
    let store = makeTestStore()

    /// Observing `favoritePhotoID(for:)` must fire `onChange` when `toggleFavorite` runs — proof the
    /// tap now drives a re-render instead of silently mutating an ignored property.
    @Test func toggleFavorite_notifiesFavoritePhotoIDObservers() {
        let manager = MeshNetworkManager(store: store)
        let post = makeWallPost()

        let recorder = FavoriteObservationRecorder()
        withObservationTracking {
            _ = manager.favoritePhotoID(for: post)
        } onChange: {
            MainActor.assumeIsolated { recorder.recordChange() }
        }

        manager.toggleFavorite(photoID: post.coverPhoto.id, in: post)

        #expect(recorder.didChange,
                "toggleFavorite must notify favoritePhotoID(for:) observers so the heart re-renders")
    }

    /// The same bump must also feed the grid: observing `photoWallPosts` (which reads the revision
    /// counter) must fire on a favorite toggle so the session cover updates live.
    @Test func toggleFavorite_notifiesPhotoWallPostsObservers() {
        let manager = MeshNetworkManager(store: store)
        let post = makeWallPost()

        let recorder = FavoriteObservationRecorder()
        withObservationTracking {
            _ = manager.photoWallPosts
        } onChange: {
            MainActor.assumeIsolated { recorder.recordChange() }
        }

        manager.toggleFavorite(photoID: post.coverPhoto.id, in: post)

        #expect(recorder.didChange,
                "toggleFavorite must notify photoWallPosts observers so the wall cover re-renders")
    }

    private func makeWallPost() -> FriendPhotoWallPost {
        let session = FriendPhotoSessionMetadata(
            id: UUID(),
            meshID: nil,
            meshName: nil,
            startedAt: Date(),
            participants: []
        )
        let photo = FriendPhotoPayload(
            imageData: Data([0x01]),
            senderName: "Tester",
            session: session
        )
        return FriendPhotoWallPost(id: session.id, session: session, photos: [photo], coverPhoto: photo)
    }
}

private final class FavoriteObservationRecorder {
    private(set) var didChange = false
    func recordChange() { didChange = true }
}
