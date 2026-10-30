import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Page 1 of Sprout's passport (World-Passport-Spec §4, `ps-sprout`, `ps-sprout-home`, `ps-parity`, §9 decoy):
/// every action the close-up, Customize and the shop offered is reachable from the page, the two machine lines,
/// the decoy's fresh passport, the care and feeling words, and the slot summaries Customize and page 1 share.
@MainActor
struct PassportSproutPageTests {
    /// A Portland reading, away from any home.
    nonisolated static let point = GeoPoint(45.5205, -122.6255)

    static func status(score: Double = 0.85, gold: Int = 1) -> WorldStatus {
        WorldStatus.make(score: score, goldHearts: gold, macros: MacroTotals(protein: 45, carbs: 200, fat: 30),
                         targets: NutritionTargets(calories: 2_000, protein: 90, carbs: 230, fat: 65, fiber: 30,
                                                   sodiumLimit: 2_300, saturatedFatLimit: 20),
                         bottles: 3, bottleTarget: 4)
    }

    nonisolated static let dressed = CompanionAppearance(bodyStyle: .pear, accessory: .flower, clothing: .scarf, sideItem: .mug)

    static func model(place: WorldCloseUpPlace = .away(point), minutes: Int? = 52, decoy: Bool = false,
                      appearance: CompanionAppearance = dressed, equipped: [CustomizationItem] = []) -> PassportSproutModel {
        PassportSproutModel.make(name: "Sprout", feeling: "Thriving · happy", state: .thriving, appearance: appearance,
                                 equipped: equipped, status: status(), listed: 3, coins: 25, friendShopMinutes: minutes,
                                 place: place, counts: PassportSproutCounts(countries: 6, continents: 3, oceans: 2, seas: 2),
                                 isDecoy: decoy)
    }

    // MARK: ps-parity

    /// Away from a home with the shops open, every close-up, Customize and shop action but Manage is on page 1.
    @Test func everyActionAwayHasItsHome() {
        let offered = Set(Self.model().actions)
        for row in PassportSproutParity.all where !row.actions.contains(.manageHomes) {
            #expect(Set(row.actions).isSubset(of: offered), "\(row.item) lost its home on page 1")
        }
    }

    /// At a home or the hotel, Manage takes This is home's place; the rest stay.
    @Test func atAHomeManageIsThere() {
        for place in [WorldCloseUpPlace.home(name: "Home"), .hotel(name: "Ace")] {
            let offered = Self.model(place: place).actions
            #expect(offered.contains(.manageHomes))
            #expect(!offered.contains(.thisIsHome))
            for row in PassportSproutParity.all where !row.actions.contains(.thisIsHome) {
                #expect(Set(row.actions).isSubset(of: Set(offered)), "\(row.item) lost its home at \(place)")
            }
        }
    }

    /// The gold Friend shops row is only there for the hour after a session; with no reading, no home row.
    @Test func friendShopsAndTheHomeRowFollowTheirRules() {
        #expect(!Self.model(minutes: nil).actions.contains(.friendShops))
        let unknown = Self.model(place: .unknown).actions
        #expect(!unknown.contains(.thisIsHome) && !unknown.contains(.manageHomes))
        #expect(unknown.last == .appColors)
        #expect(Self.model().actions.first == .pet)
    }

    // MARK: The machine-readable lines

    @Test func machineLinesAreFortyFourFilledCharacters() {
        let lines = Self.model().machineLines
        #expect(lines == ["P<FRNSPROUT" + String(repeating: "<", count: 33),
                          "FRN<C006<K03<O02<S02" + String(repeating: "<", count: 24)])
        #expect(lines.allSatisfy { $0.count == PassportMachineLines.width })
    }

    @Test func theNameFieldFoldsAndFills() {
        #expect(PassportMachineLines.nameField("Sprout") == "SPROUT")
        #expect(PassportMachineLines.nameField("Ñoño Pé-pé!") == "NONO<PE<PE")
        #expect(PassportMachineLines.nameField("  Moss  ") == "MOSS")
        #expect(PassportMachineLines.nameField("🌱") == "")
        let long = PassportMachineLines.lines(name: String(repeating: "A", count: 80), counts: .zero)[0]
        #expect(long.count == 44 && long.hasPrefix("P<FRNAAAA"))
    }

    @Test func theCountsFieldClampsItsDigits() {
        #expect(PassportMachineLines.countsField(.zero) == "FRN<C000<K00<O00<S00")
        #expect(PassportMachineLines.countsField(PassportSproutCounts(countries: 194, continents: 7, oceans: 5, seas: 140))
                == "FRN<C194<K07<O05<S99")
    }

    // MARK: Decoy (§9)

    /// A decoy is a fresh passport: Sprout as it first looked, nothing listed, 0 coins, every count 0, no friend
    /// shops and no home row, whatever the person's own page holds.
    @Test func aDecoyShowsAFreshPassport() {
        let decoy = Self.model(place: .home(name: "Home"), decoy: true)
        #expect(decoy.appearance == .standard)
        #expect(decoy.slots.map(\.value) == [CompanionBodyStyle.circle.label, CompanionAccessory.sprout.label,
                                             CompanionClothing.none.label, CompanionSideItem.none.label])
        #expect(decoy.slots.map(\.isEmpty) == [false, false, true, true])
        #expect(decoy.listed == 0 && decoy.coins == 0 && decoy.counts == .zero)
        #expect(decoy.friendShopMinutes == nil && decoy.place == .unknown)
        #expect(decoy.machineLines[1].hasPrefix("FRN<C000<K00<O00<S00<"))
        #expect(PassportSproutCopy.listed(decoy.listed, of: 6) == "Nothing listed")
    }

    // MARK: Words

    @Test func careSaysThePercentAndTheGoldHearts() {
        #expect(PassportSproutCopy.spokenCare(percent: 92, goldHearts: 1) == "Care 92 percent, one gold heart from a friend.")
        #expect(PassportSproutCopy.spokenCare(percent: 75, goldHearts: 0) == "Care 75 percent.")
        #expect(PassportSproutCopy.spokenCare(percent: 100, goldHearts: 2) == "Care 100 percent, 2 gold hearts from friends.")
    }

    @Test func feelingIsTheStateThenAWord() {
        let look = WorldCompanionLook(body: 0x5E844D)
        func text(_ emotion: CompanionEmotion?) -> String {
            PassportSproutFeeling.text(of: WorldCompanionNow(state: .thriving, look: look, pose: WorldCompanionPose(), emotion: emotion))
        }
        #expect(text(.happy) == "Thriving · happy")
        #expect(text(.frazzled) == "Thriving · a little frazzled")
        #expect(text(nil) == CompanionState.thriving.displayName)
        #expect(text(.asleep) == CompanionEmotion.asleep.displayName)
        #expect(PassportSproutCopy.photoLabel(name: "Sprout", state: "Thriving") == "Sprout, Thriving.")
    }

    @Test func shopWordsReadAsTheMockup() {
        #expect(PassportSproutCopy.listed(3, of: 6) == "3 of 6 listed")
        #expect(PassportSproutCopy.friendShopsOpen(minutes: 52) == "Open · 52 min left")
        #expect(PassportSproutCopy.friendShopsSpoken(minutes: 52) == "Friend shops, open, 52 minutes left")
        #expect(PassportSproutCopy.yourShopSpoken(listed: "3 of 6 listed", coins: 25) == "Your shop, 3 of 6 listed, 25 coins")
        #expect(PassportSproutCopy.wearingHeader(name: "Sprout") == "What Sprout's wearing")
    }

    // MARK: The shared slot summaries

    /// Page 1 and Customize show the same value per slot: the built-in, or an equipped design folded into the slot.
    @Test func slotSummariesNameWhatIsWorn() {
        let dressed = Self.model().slots
        #expect(dressed.map(\.slot) == CustomizeSlot.allCases)
        #expect(dressed.map(\.value) == [CompanionBodyStyle.pear.label, CompanionAccessory.flower.label,
                                         CompanionClothing.scarf.label, CompanionSideItem.mug.label])
        let hat = CustomizationItem(name: "My hat", slot: .hat, texture: ItemGridTexture(cols: 1, rows: 1, palette: ["#000000"], pixels: [0]),
                                    designer: ItemDesigner(id: UUID()))
        let bare = CompanionAppearance(accessory: .none)
        let summary = CustomizeSlotSummary.make(.accessory, appearance: bare, equipped: [hat])
        #expect(summary.value == "My hat" && !summary.isEmpty)
        #expect(CustomizeSlotSummary.make(.clothing, appearance: bare, equipped: [hat]).isEmpty)
    }
}
