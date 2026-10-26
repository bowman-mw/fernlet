import Foundation
import Testing
import FernletDomainModel
import WorldMapStore
@testable import Fernlet

/// Workout-space pins (World app plan step 6a): the sealed store, the matching, and the rules for when a
/// space gets its pin, loses it, or is hidden.
@MainActor
struct SpacePinTests {
    private static let gym = GeoPoint(45.5205, -122.6255)

    /// Pins round-trip through the file's bytes, and bytes that are not its format read as none.
    @Test func pinsRoundTripAndRefuseOtherBytes() throws {
        let pins = [UUID(): Self.gym, UUID(): Self.gym.offset(east: 500, north: 0)]
        #expect(SpacePinStore.decode(SpacePinStore.encode(pins)) == pins)
        #expect(SpacePinStore.decode(Data([0, 1, 2])) == nil)
        #expect(SpacePinStore.decode(Data()) == nil)
    }

    /// Set, read, match within 100 m (nearest first), remove, remove all.
    @Test func theStorePinsMatchesAndForgets() throws {
        let store = SpacePinStore(vault: .ephemeral())
        let gym = UUID(), park = UUID()
        #expect(try store.setPin(Self.gym, for: gym))
        #expect(try store.setPin(Self.gym.offset(east: 150, north: 0), for: park))
        #expect(try store.pin(for: gym) == Self.gym)
        #expect(try store.space(at: Self.gym.offset(east: 60, north: 0)) == gym)
        #expect(try store.space(at: Self.gym.offset(east: 110, north: 0)) == park, "the nearer pin wins")
        #expect(try store.space(at: Self.gym.offset(east: 400, north: 0)) == nil)
        #expect(try store.remove(for: gym))
        #expect(try store.pin(for: gym) == nil)
        #expect(store.removeAll())
        #expect(try store.all().isEmpty)
    }

    /// Only a precise reading under 50 m from the last five minutes may pin a space.
    @Test func onlyAGoodFreshReadingMayPin() {
        let now = Date()
        func fix(accuracy: Double = 10, precise: Bool = true, age: TimeInterval = 30) -> WorldFix {
            WorldFix(point: Self.gym, accuracy: accuracy, at: now.addingTimeInterval(-age), isPrecise: precise)
        }
        #expect(WorldSpacePinRules.isGoodEnough(fix(), at: now))
        #expect(!WorldSpacePinRules.isGoodEnough(fix(accuracy: 80), at: now))
        #expect(!WorldSpacePinRules.isGoodEnough(fix(precise: false), at: now))
        #expect(!WorldSpacePinRules.isGoodEnough(fix(age: 600), at: now))
    }

    /// The active space is pinned once the person said yes, keeps its first pin, is hidden in a decoy,
    /// and loses its pin when the space is deleted.
    @Test func theActiveSpaceIsPinnedOnlyWithAYes() throws {
        let store = makeTestStore()
        let defaults = try #require(UserDefaults(suiteName: "SpacePinTests.\(UUID().uuidString)"))
        let space = WorkoutLocation(name: "Riverside Gym", ownedEquipment: [])
        store.setWorkoutLocations([space], activeID: space.id)
        let now = Date(), good = WorldFix(point: Self.gym, accuracy: 8, at: now, isPrecise: true)
        #expect(!store.pinActiveWorkoutSpace(from: good, at: now, defaults: defaults), "pinned before the question was asked")
        WorldMapPreferences.setRememberSpaces(false, in: defaults)
        #expect(!store.pinActiveWorkoutSpace(from: good, at: now, defaults: defaults), "pinned after a no")
        WorldMapPreferences.setRememberSpaces(true, in: defaults)
        #expect(store.pinActiveWorkoutSpace(from: good, at: now, defaults: defaults))
        let moved = WorldFix(point: Self.gym.offset(east: 300, north: 0), accuracy: 8, at: now, isPrecise: true)
        #expect(!store.pinActiveWorkoutSpace(from: moved, at: now, defaults: defaults), "a pinned space moved")
        #expect(store.worldSpace(at: Self.gym.offset(east: 30, north: 0))?.id == space.id)
        store.duressSessionActive = true
        #expect(store.worldSpacePin(for: space.id) == nil && store.worldSpace(at: Self.gym) == nil, "a decoy saw a pin")
        store.duressSessionActive = false
        store.deleteWorkoutLocation(space.id)
        #expect(try store.worldSpacePins.pin(for: space.id) == nil, "the pin outlived its space")
    }

    /// The answer is not asked, yes or no, and the delete funnel forgets it.
    @Test func theAnswerIsTriStateAndCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "SpacePinTests.\(UUID().uuidString)"))
        #expect(WorldMapPreferences.rememberSpaces(in: defaults) == nil)
        WorldMapPreferences.setRememberSpaces(true, in: defaults)
        #expect(WorldMapPreferences.rememberSpaces(in: defaults) == true)
        WorldMapPreferences.clearAll(in: defaults)
        #expect(WorldMapPreferences.rememberSpaces(in: defaults) == nil)
    }
}
