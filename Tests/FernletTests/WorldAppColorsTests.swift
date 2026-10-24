import Foundation
import Testing
@testable import Fernlet

/// App colors' Wood and Accent (design `b2-colors`): the stored choice reads back, an unknown or missing
/// value is today's Oak and Moss, and the raw values stay the frozen tokens they are stored as.
@MainActor
struct WorldAppColorsTests {

    /// A throwaway defaults suite, removed when the test ends.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "WorldAppColorsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a defaults suite")
            return
        }
        body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    @Test func nothingStoredIsTodaysOakAndMoss() {
        withDefaults { defaults in
            #expect(WorldAppColors.current(in: defaults) == WorldAppColorChoice(wood: .oak, accent: .moss))
        }
    }

    @Test func aPickReadsBackAndAnUnknownValueFallsBack() {
        withDefaults { defaults in
            WorldAppColors.setWood(.walnut, in: defaults)
            WorldAppColors.setAccent(.sea, in: defaults)
            #expect(WorldAppColors.current(in: defaults) == WorldAppColorChoice(wood: .walnut, accent: .sea))
            #expect(defaults.string(forKey: WorldAppColors.woodKey) == "walnut")
            defaults.set("mahogany", forKey: WorldAppColors.woodKey)
            defaults.set("teal", forKey: WorldAppColors.accentKey)
            #expect(WorldAppColors.current(in: defaults) == WorldAppColorChoice(wood: .oak, accent: .moss))
        }
    }

    /// The stored raw values are tokens: renaming one would silently reset everyone's pick.
    @Test func theStoredTokensAreFrozen() {
        #expect(WorldWood.allCases.map(\.rawValue) == ["oak", "birch", "cherry", "walnut"])
        #expect(WorldAccent.allCases.map(\.rawValue) == ["moss", "sea", "plum", "clay", "sun"])
        #expect(WorldAppColors.woodKey == "fernlet.world.appColors.wood")
        #expect(WorldAppColors.accentKey == "fernlet.world.appColors.accent")
    }
}
