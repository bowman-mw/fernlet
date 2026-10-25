import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Round 6's smaller fixes (lane "fixes"): the photo prints' one-read cache (W-04) and a print opening its
/// photo (`ref-wall-photo`).
@MainActor
struct WorldRoundSixFixesTests {

    // MARK: W-04 · the prints read each thumbnail once

    /// A wall reads only the photos its cache doesn't hold, each once, and never more than four.
    @Test func thePrintsReadOnlyWhatTheyLack() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, b, nil, c], cached: []) == [a, b, c])
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, b, nil, c], cached: [a, c]) == [b])
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, a, b, b], cached: []) == [a, b], "a photo twice is read once")
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, b, c, d, e], cached: []) == [a, b, c, d], "four prints at most")
        #expect(WorldPhotoPrints.idsToRead(wanted: [nil, nil, nil, nil], cached: []).isEmpty, "an empty wall reads nothing")
    }

    /// The prints read nothing in `body`: the thumbnail read sits in the load task alone, behind the
    /// protected-data check, and the cache is the only place a print's image comes from.
    @Test func thePrintsNeverDecodeInBody() throws {
        let source = try RepoRoot.source("App/Fernlet/World/Home/WorldPhotoPrints.swift")
        #expect(source.components(separatedBy: "thumbnailData(forPhotoID:").count == 2, "one read site")
        #expect(source.contains("guard UIApplication.shared.isProtectedDataAvailable else { return }"))
        #expect(source.contains(".task(id: LoadKey("))
        #expect(source.contains("byPreparingForDisplay()"), "decoded off the main actor")
        #expect(!source.contains("Image(uiImage: UIImage(data:"), "no decode while drawing")
    }

    // MARK: ref-wall-photo · a print opens its photo

    /// A print goes by its hangout's name, else by the friend who took it.
    @Test func aPrintIsNamedForItsHangoutElseItsFriend() {
        let session = FriendPhotoSessionMetadata(id: UUID(), meshID: nil, meshName: " Picnic ", startedAt: .now, participants: [])
        let inHangout = FriendPhotoPayload(imageData: Data([1]), senderName: "Sam", session: session)
        let alone = FriendPhotoPayload(imageData: Data([1]), senderName: "Sam")
        let unnamed = FriendPhotoPayload(imageData: Data([1]), senderName: "Rae",
                                         session: FriendPhotoSessionMetadata(id: UUID(), meshID: nil, meshName: "  ", startedAt: .now, participants: []))
        #expect(WorldPhotoPrints.name(of: inHangout) == "Picnic")
        #expect(WorldPhotoPrints.name(of: alone) == "Sam")
        #expect(WorldPhotoPrints.name(of: unnamed) == "Rae")
        #expect(WorldPhotoPrints.spokenTitle(of: inHangout).hasPrefix("Photo from Picnic, "))
    }

    /// The route a print hands Home is the photo itself; the album presents it, never pushes it.
    @Test func aWallPhotoIsARouteTheAlbumPresents() throws {
        let id = UUID()
        #expect(FriendsRoute.wallPhoto(id) == .wallPhoto(id))
        #expect(FriendsRoute.closingShop([.wallPhoto(id)]) == [.wallPhoto(id)])
        let album = try RepoRoot.source("App/Fernlet/ConnectView.swift")
        #expect(album.contains("if case .wallPhoto(let photoID) = route"), "the album takes it as a cover, not a page")
        #expect(album.contains("initialPhotoID: feedOpenedFromWall"), "the carousel opens at that photo")
        #expect(album.contains("onBack: feedOpenedFromWall == nil ? nil"), "‹ Album only when the wall opened it")
    }
}
