import Foundation
import Testing
import FernletDomainModel
import WorldMapStore
@testable import Fernlet

/// The blue button's card at a home or the hotel (`ref-home-blue` draft 2, owner-approved 2026-10-26;
/// Refinements group 12): the home's rows, the workout row only with a space set up at home, the loop from
/// the door, the hotel's room workout, and what a loop is.
@MainActor
struct WorldHomeCardTests {
    private static let homeSpace = WorldQuickStartContext.Space(id: UUID(), name: "Home space",
                                                                equipment: "Dumbbells, Yoga mat", itemCount: 2)
    private static let laurelhurst = GeoPoint(45.5229, -122.6265)

    /// Standing at a home called `name`, able to walk.
    private static func atHome(_ name: String = "Our flat") -> WorldQuickStartContext {
        var context = WorldQuickStartContext()
        context.canWalk = true
        context.base = WorldQuickStartContext.Base(name: name, isHotel: false)
        return context
    }

    // MARK: At home

    /// Draft 2: without a home space there is no workout row; the card is titled with the home's name and
    /// says "You're home. Here's what's handy."; Cook something and Walk or run together follow.
    @Test func atHomeWithoutASpaceOffersNoWorkout() throws {
        let card = try #require(WorldQuickStart.card(for: Self.atHome()))
        #expect(card.heading == .home("Our flat") && card.note == .atHome)
        #expect(card.options == [.cookSomething, .walkTogether])
        #expect(WorldQuickStart.glyph(for: Self.atHome()) == .walk)
        #expect(WorldQuickStartCopy.heading(card.heading) == "Our flat")
        #expect(WorldQuickStartCopy.note(.atHome) == "You're home. Here's what's handy.")
    }

    /// With a space set up at home, "Suggest today's workout · Home space · …" leads; the latest loop from
    /// the door comes next, then cooking and the walk.
    @Test func aHomeSpaceLeadsAndTheLoopFollows() throws {
        var context = Self.atHome()
        context.homeSpace = Self.homeSpace
        context.loopMetres = 2_100
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.options == [.suggestWorkout(space: "Home space", equipment: "Dumbbells, Yoga mat", gentle: false),
                                 .loopFromDoor(metres: 2_100), .cookSomething, .walkTogether])
        #expect(WorldQuickStartCopy.detail(card.options[0]) == "Home space · Dumbbells, Yoga mat")
        #expect(WorldQuickStartCopy.title(.loopFromDoor(metres: 2_100)) == "Around the block again")
        #expect(WorldQuickStartCopy.detail(.loopFromDoor(metres: 2_100)).hasSuffix("loop from your door"))
        #expect(WorldQuickStartCopy.title(.cookSomething) == "Cook something")
        #expect(WorldQuickStartCopy.detail(.cookSomething) == "From your recipe book")
        context.plannedSession = "Full body"
        let planned = try #require(WorldQuickStart.card(for: context))
        #expect(planned.options.first == .todaysPlan(space: "Home space", session: "Full body"),
                "a plan at the home space still starts in one tap, as at any space")
    }

    /// The loop needs a walk to be possible; without location the card keeps cooking alone.
    @Test func theLoopWaitsForAWalk() throws {
        var context = Self.atHome()
        context.loopMetres = 2_100
        context.canWalk = false
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.options == [.cookSomething])
    }

    /// A resting day at home: "Resting counts today", the gentle stretch first, the home's workout gently.
    @Test func aRestingDayAtHomeIsGentle() throws {
        var context = Self.atHome()
        context.isResting = true
        context.hasGentleStretch = true
        context.homeSpace = Self.homeSpace
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.note == .restingCounts)
        #expect(card.options == [.gentleStretch, .suggestWorkout(space: "Home space", equipment: "Dumbbells, Yoga mat", gentle: true),
                                 .cookSomething, .walkTogether])
    }

    /// Home wins over a favourite place to eat near the door, and friends nearby still end the card.
    @Test func homeComesBeforeEatingAndKeepsFriends() throws {
        var context = Self.atHome()
        context.eatingPlace = WorldQuickStartContext.EatingOut(id: UUID(), name: "Hoshi", meals: 4, usual: "Ramen")
        context.canMeetFriends = true
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .home("Our flat"))
        #expect(card.options == [.cookSomething, .walkTogether, .friendsNearby])
    }

    /// A decoy never sees the home card: only the walk.
    @Test func aDecoyGetsOnlyTheWalk() throws {
        var context = Self.atHome()
        context.isDecoy = true
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .walk && card.options == [.walkTogether])
    }

    // MARK: At a hotel

    /// The hotel's card: its name, Suggest a room workout (no equipment, nothing to set up), the walk.
    @Test func aHotelOffersTheRoomWorkout() throws {
        var context = Self.atHome("The Ace")
        context.base = WorldQuickStartContext.Base(name: "The Ace", isHotel: true)
        context.homeSpace = Self.homeSpace
        context.loopMetres = 2_100
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .hotel("The Ace") && card.note == nil)
        #expect(card.options == [.roomWorkout(gentle: false), .walkTogether], "no home space, loop or cooking at a hotel")
        #expect(WorldQuickStartCopy.title(.roomWorkout(gentle: false)) == "Suggest a room workout")
        #expect(WorldQuickStartCopy.detail(.roomWorkout(gentle: false)) == "No equipment · nothing to set up")
        context.isResting = true
        let resting = try #require(WorldQuickStart.card(for: context))
        #expect(resting.note == .restingCounts && resting.options == [.roomWorkout(gentle: true), .walkTogether])
    }

    // MARK: Loops from the door

    /// A loop starts and ends within ~150 m of the same home and is at least 300 m long.
    @Test func aLoopStartsAndEndsAtTheDoor() {
        let home = Self.laurelhurst
        let out = home.offset(east: 900, north: 400)
        let loop = [home.offset(east: 20, north: 10), out, home.offset(east: -60, north: 40)]
        #expect(WorldLoopRule.isLoop(loop, metres: 2_100, homes: [home]))
        #expect(!WorldLoopRule.isLoop([home, out], metres: 1_000, homes: [home]), "ending away is a walk, not a loop")
        #expect(!WorldLoopRule.isLoop([out, home], metres: 1_000, homes: [home]), "starting away is not from the door")
        #expect(!WorldLoopRule.isLoop(loop, metres: 120, homes: [home]), "a few steps in the garden are not a loop")
        #expect(!WorldLoopRule.isLoop(loop, metres: 2_100, homes: []), "no home, no loop")
        #expect(!WorldLoopRule.isLoop([home.offset(east: 160, north: 0), out, home], metres: 2_100, homes: [home]))
        let second = home.offset(east: 5_000, north: 0)
        #expect(WorldLoopRule.isLoop([second, second.offset(east: 800, north: 0), second], metres: 1_600, homes: [home, second]),
                "either home's door counts")
    }

    // MARK: The room space

    /// The room workout adds one space with no equipment the first time and only makes it active after.
    @Test func theRoomWorkoutAddsOneEmptySpace() {
        let store = makeTestStore()
        store.prepareRoomWorkout()
        store.prepareRoomWorkout()
        let rooms = store.settings.workoutLocations.filter { $0.id == FernletStore.worldRoomSpaceID }
        #expect(rooms.count == 1)
        #expect(rooms.first?.ownedEquipment.isEmpty == true)
        #expect(store.settings.activeWorkoutLocationID == FernletStore.worldRoomSpaceID)
    }
}
