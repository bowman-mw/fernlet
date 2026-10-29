// BodybuildingQuickLogTests.swift
// FernletTests
//
// The Bodybuilding goal on the Log panel and Log meal (World bodybuilding spec §5–§6, round 7 piece D):
// the frozen `bathroom` shortcut token and its parking on an older build, Bathroom taking Care's place
// once and the person's own swap winning afterwards, another goal hiding it for display only (nothing
// deleted, back on return), the tile's tap and fix through an in-memory sealed tally store, and the
// Free meal tag's visibility and sealing rules. No test here touches the simulator's real journal
// device key: the real store is only driven in a decoy, which drops before any key is read.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletLock
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct BodybuildingQuickLogTests {
    private static let defaultSeated: [FernletShortcut] = [.meal, .water, .bathroom, .move, .sleep, .journal]

    private func makeStore(goal: GoalType = .bodybuilding) -> FernletStore {
        let store = makeTestStore()
        store.settings.selectedGoal = goal
        return store
    }

    private func decode(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    // MARK: - The token

    /// "bathroom" is the frozen token, and a layout holding it survives a save and a load.
    @Test func theBathroomTokenRoundTrips() throws {
        #expect(FernletShortcut(rawValue: "bathroom") == .bathroom)
        var settings = FernletSettings()
        settings.quickLogItems = Self.defaultSeated
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["quickLogItems"] as? [String] == ["meal", "water", "bathroom", "move", "sleep", "journal"])
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)
        #expect(decoded.quickLogItems == Self.defaultSeated)
        #expect(decoded.unknownQuickLogTokens.isEmpty)
    }

    /// An older build parks "bathroom" in `unknownQuickLogTokens` (its five known tiles unpadded) and
    /// writes it back; this build adopts it again from there.
    @Test func aBathroomTokenParkedByAnOlderBuildIsAdoptedAgain() throws {
        let settings = try decode("""
        {"quickLogItems": ["meal", "water", "move", "sleep", "journal"], "unknownQuickLogTokens": ["bathroom"]}
        """)
        #expect(settings.quickLogItems.contains(.bathroom))
        #expect(settings.unknownQuickLogTokens.isEmpty)
        let parkedElsewhere = try decode("""
        {"quickLogItems": ["meal", "futureShortcut", "water", "bathroom"]}
        """)
        #expect(parkedElsewhere.quickLogItems == [.meal, .water, .bathroom])
        #expect(parkedElsewhere.unknownQuickLogTokens == ["futureShortcut"])
    }

    /// Bathroom is never a default tile and never fills an empty slot.
    @Test func bathroomIsNeverADefaultOrAFiller() {
        #expect(!FernletShortcut.defaultQuickLog.contains(.bathroom))
        #expect(!FernletShortcut.normalizedQuickLog([]).contains(.bathroom))
        let crowded: [FernletShortcut] = [.meal, .water, .move, .sleep, .journal, .care, .friends]
        #expect(!FernletShortcut.normalizedQuickLog(crowded.filter { $0 != .care }).contains(.bathroom))
        #expect(FernletShortcut.normalizedQuickLog(Self.defaultSeated) == Self.defaultSeated)
        #expect(SensitiveSurfaceVisibility.all.allows(.bathroom))
    }

    // MARK: - Seating and hiding (pure)

    /// Bathroom takes Care's place, drawn right after Water, as `bb-bowel` draws the six.
    @Test func bathroomTakesCaresPlaceAfterWater() {
        #expect(FernletShortcut.seatingBathroom(in: FernletShortcut.defaultQuickLog) == Self.defaultSeated)
        #expect(FernletShortcut.seatingBathroom(in: Self.defaultSeated) == Self.defaultSeated, "already seated")
        let noWater: [FernletShortcut] = [.meal, .move, .care, .sleep, .journal, .friends]
        #expect(FernletShortcut.seatingBathroom(in: noWater) == [.meal, .move, .bathroom, .sleep, .journal, .friends])
        let noCare: [FernletShortcut] = [.meal, .water, .move, .sleep, .journal, .friends]
        #expect(FernletShortcut.seatingBathroom(in: noCare) == noCare, "nothing of the person's is pushed out")
    }

    /// Without the goal, Care shows where Bathroom sits; with Care already shown, Bathroom just leaves.
    @Test func anotherGoalShowsCareWhereBathroomSits() {
        let hidden = FernletShortcut.visibleQuickLog(Self.defaultSeated, visibility: .all)
        #expect(hidden == [.meal, .water, .care, .move, .sleep, .journal])
        #expect(FernletShortcut.visibleQuickLog(Self.defaultSeated, visibility: .all, bathroomAvailable: true) == Self.defaultSeated)
        let both: [FernletShortcut] = [.meal, .bathroom, .care, .move, .sleep, .journal]
        let shown = FernletShortcut.visibleQuickLog(both, visibility: .all)
        #expect(!shown.contains(.bathroom) && shown.count == 6)
        #expect(!FernletShortcut.selectableQuickLogItems(visibility: .all).contains(.bathroom))
        #expect(FernletShortcut.selectableQuickLogItems(visibility: .all, bathroomAvailable: true).contains(.bathroom))
    }

    // MARK: - The store

    /// Choosing Bodybuilding seats the tile once; Care swapped back in by the person stays.
    @Test func theTileIsSeatedOnceAndThePersonsSwapWins() {
        let store = makeStore()
        store.seatBathroomTileIfNeeded()
        #expect(store.settings.quickLogItems == Self.defaultSeated)
        #expect(store.bodybuildingCalendarSettings.bathroomTileSeeded)
        #expect(store.visibleQuickLogItems == Self.defaultSeated)
        store.setQuickLogItems(FernletShortcut.defaultQuickLog)
        store.seatBathroomTileIfNeeded()
        #expect(store.settings.quickLogItems == FernletShortcut.defaultQuickLog, "the person's own choice wins")
    }

    /// Another goal hides the tile for display only and seats nothing; choosing Bodybuilding again shows
    /// it again, with nothing deleted.
    @Test func switchingGoalsHidesTheTileAndBackShowsItAgain() {
        let store = makeStore()
        store.seatBathroomTileIfNeeded()
        store.settings.selectedGoal = .strength
        #expect(!store.isBathroomTileAvailable)
        #expect(store.visibleQuickLogItems == [.meal, .water, .care, .move, .sleep, .journal])
        #expect(store.settings.quickLogItems == Self.defaultSeated, "the stored layout keeps the tile")
        store.settings.selectedGoal = .bodybuilding
        #expect(store.visibleQuickLogItems == Self.defaultSeated)

        let other = makeStore(goal: .wellness)
        other.seatBathroomTileIfNeeded()
        #expect(other.settings.quickLogItems == FernletShortcut.defaultQuickLog)
        #expect(!other.bodybuildingCalendarSettings.bathroomTileSeeded)
    }

    /// A decoy session seats nothing, shows no count and keeps no tag.
    @Test func aDecoySeatsNothingAndKeepsNoTag() {
        let store = makeStore()
        store.duressSessionActive = true
        store.seatBathroomTileIfNeeded()
        #expect(store.settings.quickLogItems == FernletShortcut.defaultQuickLog)
        #expect(!store.bodybuildingCalendarSettings.bathroomTileSeeded)
        #expect(store.bathroomVisits(on: store.todayKey) == 0)
        #expect(store.addBathroomVisit(on: store.todayKey) == .droppedInDecoy)
        let meal = Meal(name: "Pizza", mealType: .dinner, macros: Macros(protein: 30, carbs: 90, fat: 30), mealSource: .manual,
                        isAIFallback: false, quality: .good, confidence: MealConfidence.logged.token, note: "", source: "manual")
        #expect(store.tagFreeMeals([meal], loggedTo: nil) == [.droppedInDecoy])
        #expect(!store.isFreeMeal(meal.id, on: store.todayKey))
    }

    /// The Tag row (and the Bathroom tile) show only while Bodybuilding is the goal.
    @Test func theTagRowShowsOnlyForBodybuilding() {
        let store = makeStore()
        #expect(store.isBathroomTileAvailable)
        for goal in GoalType.allCases where goal != .bodybuilding {
            store.settings.selectedGoal = goal
            #expect(!store.isBathroomTileAvailable, "\(goal)")
        }
    }

    // MARK: - The tile's tap and fix, on an in-memory sealed store

    /// One tap adds one; the fix sets the count inside 0...30; each result feels as it should.
    @Test func tapAddsOneAndFixSetsTheCount() {
        let controller = PrivatePersistenceController(inMemory: true)
        let service = "com.fernlet.journal.test.bathroomtile.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        let tallies = BodyTallyStore(controller: controller, deviceKeyService: service)
        let day = "2026-10-29"
        let first = tallies.addBathroomVisit(on: day, isDecoy: false)
        #expect(first == .saved)
        #expect(BathroomTileFeedback.event(for: first) == .logged)
        #expect(tallies.addBathroomVisit(on: day, isDecoy: false) == .saved)
        #expect(tallies.tally(on: day, isDecoy: false)?.bathroomVisits == 2)
        #expect(tallies.setBathroomVisits(BathroomTileFeedback.clamped(45), on: day, isDecoy: false) == .saved)
        #expect(tallies.tally(on: day, isDecoy: false)?.bathroomVisits == 30)
        let atCap = tallies.addBathroomVisit(on: day, isDecoy: false)
        #expect(atCap == .atLimit && BathroomTileFeedback.event(for: atCap) == .limit)
        #expect(BathroomTileFeedback.clamped(-3) == 0)
        #expect(BathroomTileFeedback.event(for: .unchanged) == nil)
        #expect(BathroomTileFeedback.event(for: .droppedInDecoy) == .logged, "a decoy shows no error")
        #expect(BathroomTileFeedback.announcesFailure(.failed(.storeError)))
        #expect(!BathroomTileFeedback.announcesFailure(.saved))
    }

    // MARK: - The Free meal tag's reporter

    /// Log meal's reporter hands the meals and their day to the tag first, then to the toast.
    @Test func theTagIsSealedBeforeTheToastReports() {
        var order: [String] = []
        var taggedDay: String?? = .none
        let reporter = MealLogReporter { _, _, _ in order.append("toast") }
            .first { meals, dayKey in
                order.append("tag \(meals.count)")
                taggedDay = .some(dayKey)
            }
        reporter([])
        #expect(order == ["tag 0", "toast"])
        #expect(taggedDay == .some(nil), "today's log hands no day key")
    }
}
