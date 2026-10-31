import Foundation
import Testing
@testable import Fernlet

/// The Album round (World Review Batch 4, `b4-mem-*`, approved 2026-10-24): Friends renamed Album with
/// its old name kept for Voice Control, the album page holding only the album, the blue button's friend
/// cards, Friends nearby's cards for who is nearby, and the Friends group in Settings.
@MainActor
struct WorldAlbumTests {

    // MARK: b4-mem-name

    /// The item bar and the plate say Album; the tokens stay; Voice Control still answers to Friends.
    @Test func theFriendsPanelIsNamedAlbumAndStillAnswersToFriends() {
        #expect(WorldPanel.friends.barName == "Album")
        #expect(WorldPanel.friends.title == "Album")
        #expect(WorldPanel.friends.inputNames == ["Album", "Friends"])
        #expect(WorldPanel.food.inputNames == ["Food"], "only the renamed slot carries a second name")
        // Tokens never change: the raw value, the identifier and the tab.
        #expect(WorldPanel.friends.rawValue == "friends")
        #expect(WorldPanel.friends.itemIdentifier == "world.item.friends")
        #expect(WorldPanel.friends.tab == .social)
    }

    /// The album's page carries no friend controls: no header buttons, no looking or session row, no
    /// shop row, and no camera of its own (`b4-mem-root`, `b4-mem-session`).
    @Test func theAlbumPageIsOnlyTheAlbum() throws {
        let album = try RepoRoot.source("App/Fernlet/ConnectView.swift")
        for gone in ["FriendsHeaderButtons(", "FriendsSessionRow(", "Looking for nearby friends", "Friend shops are open",
                     "DisposableCameraView(", "NearbySlotRow"] {
            #expect(!album.contains(gone), "the Album page still carries \(gone)")
        }
        #expect(album.contains("ScreenHeader(title: \"Album\", subtitle: \"Together, and just you.\", identifier: \"screen.friends\")"))
        // Photos waiting for you stays on top after a session.
        let header = try #require(album.range(of: "private var albumHeader: some View {"))
        let waiting = try #require(album.range(of: "pendingPhotoReviewCard", range: header.upperBound..<album.endIndex))
        let resume = try #require(album.range(of: "sessionResumeBanner", range: header.upperBound..<album.endIndex))
        #expect(waiting.lowerBound < resume.lowerBound, "Photos waiting for you is the first card")
    }

    // MARK: Friends nearby (b4-mem-blue-friend, -blue-join; -blue-new retired 2026-10-31)

    /// Who a nearby phone is: a friend, someone in an open hangout, or "Someone nearby" — a phone that
    /// isn't a friend's has no someone-new kind any more (World Friends spec §1.1: someone new is met by
    /// tapping phones on Home).
    @Test func aNearbyPhoneIsAFriendAHangoutOrSomeoneNearby() {
        #expect(FriendsNearbyKind.classify(friendName: "Sam", discoveryInfo: ["v": "1"]) == .friend(name: "Sam"))
        #expect(FriendsNearbyKind.classify(friendName: nil, discoveryInfo: nil) == .unknown,
                "a phone that isn't a friend's reads as Someone nearby, never as someone new")
        let open = ["v": "1", "meshName": "Picnic", "memberCount": "2"]
        #expect(FriendsNearbyKind.classify(friendName: "Sam", discoveryInfo: open)
                == .hangout(friend: "Sam", hangoutName: "Picnic", others: 1))
        #expect(FriendsNearbyKind.classify(friendName: nil, discoveryInfo: open)
                == .hangout(friend: nil, hangoutName: "Picnic", others: 1))
        // A blank or missing hangout name is no hangout (a closed one advertises nothing).
        #expect(FriendsNearbyKind.classify(friendName: "Sam", discoveryInfo: ["meshName": "  "]) == .friend(name: "Sam"))
        #expect(FriendsNearbyKind.classify(friendName: nil, discoveryInfo: ["meshName": "Picnic"])
                == .hangout(friend: nil, hangoutName: "Picnic", others: 0))
    }

    /// The cards' words are the approved ones.
    @Test func theCardsSayWhatTheApprovedCardsSay() {
        let someone = "Someone nearby"
        let sam = FriendsNearbyKind.friend(name: "Sam")
        #expect(FriendsNearbyCopy.heading(sam, someoneNearby: someone) == "Sam is nearby")
        #expect(FriendsNearbyCopy.title(sam, someoneNearby: someone) == "Start a hangout with Sam")
        #expect(FriendsNearbyCopy.detail(sam) == "Photos, messages and walks together, while you're in person")
        let picnic = FriendsNearbyKind.hangout(friend: "Sam", hangoutName: "Picnic", others: 1)
        #expect(FriendsNearbyCopy.note(picnic) == "Sam is in a hangout with 1 other person.", "the count's plural forms")
        #expect(FriendsNearbyCopy.note(.hangout(friend: "Sam", hangoutName: "Picnic", others: 3)) == "Sam is in a hangout with 3 other people.")
        #expect(FriendsNearbyCopy.note(.hangout(friend: nil, hangoutName: "Picnic", others: 1)) == "They're in a hangout with 1 other person.")
        #expect(FriendsNearbyCopy.title(picnic, someoneNearby: someone) == "Join Sam's hangout")
        #expect(FriendsNearbyCopy.detail(picnic) == "Picnic · Sam says yes before you're in")
        // No someone-new words: a phone that isn't a friend's, in a hangout or not, is the placeholder.
        #expect(FriendsNearbyCopy.heading(.unknown, someoneNearby: someone) == someone)
        #expect(FriendsNearbyCopy.title(.unknown, someoneNearby: someone) == someone)
        #expect(FriendsNearbyCopy.note(.unknown) == nil && FriendsNearbyCopy.detail(.unknown) == nil)
        #expect(FriendsNearbyCopy.heading(.hangout(friend: nil, hangoutName: "Picnic", others: 1), someoneNearby: someone) == someone)
    }

    // MARK: The blue button (b4-mem-blue-friend)

    /// A context where walking is possible and friends are offered.
    private static func friendly() -> WorldQuickStartContext {
        var context = WorldQuickStartContext()
        context.canWalk = true
        context.canMeetFriends = true
        return context
    }

    /// A friend nearby: Start a hangout with Sam, Start an activity, then the usual choices.
    @Test func aFriendNearbyLeadsWithASessionAndAnActivity() throws {
        var context = Self.friendly()
        context.nearbyFriends = ["Sam"]
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .friendNearby(["Sam"]))
        #expect(card.options == [.startSession(friend: "Sam"), .startActivity, .walkTogether])
        #expect(WorldQuickStart.glyph(for: context) == .friends)
        #expect(WorldQuickStartCopy.heading(card.heading) == "Sam is nearby")
        #expect(WorldQuickStartCopy.title(.startSession(friend: "Sam")) == "Start a hangout with Sam")
        #expect(WorldQuickStartCopy.spokenStatus(card) == "Sam is nearby. Start a hangout or an activity.")
        context.nearbyFriends = ["Sam", "Rae"]
        #expect(WorldQuickStartCopy.heading(.friendNearby(["Sam", "Rae"])) == "Sam and Rae are nearby")
    }

    /// No friend heard: the usual card, with Friends nearby last, so starting or joining a hangout with
    /// friends stays reachable (presence can't hear people who aren't friends; someone new is a tap).
    @Test func withoutAFriendNearbyFriendsNearbyComesLast() throws {
        let context = Self.friendly()
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .walk && card.options == [.walkTogether, .friendsNearby])
        #expect(WorldQuickStart.glyph(for: context) == .walk, "the usual card keeps its icon")
        #expect(WorldQuickStartCopy.spokenStatus(card) == nil)
        var nowhere = context
        nowhere.canWalk = false
        let alone = try #require(WorldQuickStart.card(for: nowhere))
        #expect(alone.heading == .inPerson && alone.options == [.friendsNearby])
        #expect(WorldQuickStart.glyph(for: nowhere) == .friends)
    }

    /// Never in a decoy, never when friends aren't offered, and a session's card is the session's.
    @Test func friendsStayOutOfADecoyAndASession() throws {
        var decoy = Self.friendly()
        decoy.isDecoy = true
        decoy.canMeetFriends = false
        decoy.nearbyFriends = ["Sam"]
        #expect(WorldQuickStart.card(for: decoy)?.options == [.walkTogether])
        var off = Self.friendly()
        off.canMeetFriends = false
        off.nearbyFriends = ["Sam"]
        #expect(WorldQuickStart.card(for: off)?.options == [.walkTogether], "friends not offered: the usual card")
        var session = Self.friendly()
        session.nearbyFriends = ["Sam"]
        session.session = WorldQuickStartContext.Session(names: ["Sam"], shotsLeft: 3)
        #expect(WorldQuickStart.card(for: session)?.options == [.sessionCamera(shotsLeft: 3), .walkTogether])
        var walking = Self.friendly()
        walking.nearbyFriends = ["Sam"]
        walking.activity = .walking
        #expect(WorldQuickStart.card(for: walking) == nil, "a walk with no camera offers nothing new")
    }

    // MARK: Settings (b4-mem-settings-friends)

    /// Settings search finds Friends & Blocks and Change name, and both open Friends & Blocks.
    @Test func settingsSearchFindsFriendsAndBlocksAndChangeName() {
        for query in ["friends & blocks", "change name", "blocked", "you appear as"] {
            let results = SettingsSearchIndex.results(for: query)
            #expect(results.contains { $0.route == .friendsBlocks }, "'\(query)' doesn't reach Friends & Blocks")
        }
    }

    /// The Settings root carries the Friends group right after Your day and Home map, with Friends & Blocks first.
    @Test func settingsHasAFriendsGroupAfterYourDay() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        // Home map (World build step 5c, `b2-settings-root`) sits between Your day and Friends.
        let day = try #require(sheet.range(of: "            yourDaySection\n            homeMapSection\n            friendsSection\n"))
        #expect(!day.isEmpty)
        #expect(sheet.contains("hubLink(\"Friends & Blocks\", subtitle: friendsRowSubtitle, .friendsBlocks)"))
        #expect(sheet.contains("case .friendsBlocks:\n            // The page the Friends tab's header used to push (b2-friend-list), with Back to Settings.\n            FriendListView("))
    }
}
