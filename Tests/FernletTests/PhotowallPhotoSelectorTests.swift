import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct PhotowallPhotoSelectorTests {
    @Test func nextLaunchPrefersPhotosNotShownOnPreviousLaunch() {
        let defaults = makeDefaults()
        let photos = (0..<8).map { index in
            FriendPhotoPayload(imageData: Data([UInt8(index)]), senderName: "Friend")
        }
        let selector = PhotowallPhotoSelector(
            defaults: defaults,
            historyKey: "previous",
            ranking: StablePhotowallPhotoRanking()
        )

        let first = selector.selectPhotoIDs(from: photos, count: 4, context: context)
        let second = selector.selectPhotoIDs(from: photos, count: 4, context: context)

        #expect(Set(first).isDisjoint(with: Set(second)))
    }

    @Test func rankingStrategyControlsSelectionOrder() {
        let defaults = makeDefaults()
        let photos = (0..<4).map { index in
            FriendPhotoPayload(imageData: Data([UInt8(index)]), senderName: "Friend")
        }
        let selector = PhotowallPhotoSelector(
            defaults: defaults,
            historyKey: "ranked",
            ranking: ReversePhotowallPhotoRanking()
        )

        let selected = selector.selectPhotoIDs(from: photos, count: 4, context: context)

        #expect(selected == photos.reversed().map(\.id))
    }

    private var context: PhotowallSelectionContext {
        PhotowallSelectionContext(selectedAt: Date(timeIntervalSince1970: 0), derivedSignals: [], recentActivityNames: [])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PhotowallPhotoSelectorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct StablePhotowallPhotoRanking: PhotowallPhotoRanking {
    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload] {
        _ = context
        return photos
    }
}

private struct ReversePhotowallPhotoRanking: PhotowallPhotoRanking {
    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload] {
        _ = context
        return photos.reversed()
    }
}
